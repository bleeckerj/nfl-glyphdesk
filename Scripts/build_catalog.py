"""Convert Unicode, Emoji and CLDR data into a read-only SQLite catalog."""
from bisect import bisect_right
from collections import defaultdict
import json
from pathlib import Path
import re
import sqlite3
import sys
from xml.etree import ElementTree
from zipfile import ZipFile

def rows(text):
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            yield [field.strip() for field in line.split(";")]

def ranges(text):
    indexed = []
    for interval, label, *_ in rows(text):
        start, *end = [int(code, 16) for code in interval.split("..")]
        indexed.append((start, end[0] if end else start, label))
    indexed.sort()
    starts = [start for start, _, _ in indexed]
    def find(code, default):
        index = bisect_right(starts, code) - 1
        return indexed[index][2] if index >= 0 and code <= indexed[index][1] else default
    return find

def algorithmic_name(stem, code):
    if stem == "Hangul Syllable":
        letters = ["G GG N D DD R M B BB S SS _ J JJ C K T P H",
                   "A AE YA YAE EO E YEO YE O WA WAE OE YO U WEO WE WI YU EU YI I",
                   "_ G GG GS N NJ NH D L LG LM LB LS LT LP LH M B BS S SS NG J C K T P H"]
        lead, vowel, tail = (piece.split() for piece in letters)
        offset = code - 0xAC00
        return "HANGUL SYLLABLE " + (lead[offset // 588] + vowel[(offset % 588) // 28] + tail[offset % 28]).replace("_", "")
    for prefix, name in (
        ("CJK Ideograph", "CJK UNIFIED IDEOGRAPH"),
        ("Tangut Ideograph", "TANGUT IDEOGRAPH"),
        ("Seal Ideograph", "SEAL IDEOGRAPH"),
    ):
        if stem.startswith(prefix):
            return f"{name}-{code:04X}"
    return f"{stem.upper()}-{code:04X}"

def key_for(text):
    return " ".join(f"{ord(character):X}" for character in text)

def code_key(raw):
    return " ".join(f"{int(code, 16):X}" for code in raw.split())

def build(reference, output):
    with ZipFile(reference) as archive:
        data = {name: archive.read(name).decode("utf-8-sig") for name in archive.namelist()}
    block = ranges(data["Blocks.txt"])
    script = ranges(data["Scripts.txt"])
    aliases = defaultdict(list)
    for code, name, *_ in rows(data["NameAliases.txt"]):
        aliases[code_key(code)].append(name)
    for line in data["Unihan-readings.txt"].splitlines():
        code, _, keyword = line.split("\t", 2)
        aliases[code_key(code[2:])].append(keyword)
    localized_names = {}
    for name, xml in data.items():
        if not name.endswith(".xml"):
            continue
        for annotation in ElementTree.fromstring(xml).iter("annotation"):
            if not annotation.text or annotation.text == "↑↑↑":
                continue
            key = key_for(annotation.get("cp"))
            aliases[key].append(annotation.text.replace("|", " "))
            if name.endswith("/en.xml") and annotation.get("type") == "tts":
                localized_names[key] = annotation.text
    entries = {}
    pending = None
    for row in rows(data["UnicodeData.txt"]):
        code, title, category, *rest = row
        value = int(code, 16)
        if title.endswith(", First>"):
            pending = (value, title[1:].split(",")[0], category)
            continue
        if title.endswith(", Last>"):
            start, stem, kind = pending
            pending = None
            if kind in {"Cs", "Co"}:
                continue
            for cp in range(start, value + 1):
                key = f"{cp:X}"
                entries[key] = (key, algorithmic_name(stem, cp), block(cp, "Other"), script(cp, "Unknown"), kind, cp, "")
            continue
        if title == "<control>":
            title = (aliases[f"{value:X}"] or [rest[7] or f"CONTROL {value:04X}"])[0]
        key = f"{value:X}"
        entries[key] = (key, title, block(value, "Other"), script(value, "Common"), category, value, "")
    for raw, description in rows(data["NamedSequences.txt"]):
        key = code_key(description)
        cp = int(key.split()[0], 16)
        entries.setdefault(key, (key, raw, block(cp, "Other"), script(cp, "Common"), "Sequence", cp, ""))
    for filename in ("StandardizedVariants.txt", "emoji/emoji-variation-sequences.txt"):
        for raw, description, *_ in rows(data[filename]):
            key = code_key(raw)
            base = key.split()[0]
            cp = int(base, 16)
            title = entries.get(base, ("", f"U+{cp:04X}"))[1]
            entries.setdefault(key, (key, f"{title} ({description})", block(cp, "Other"), script(cp, "Common"), "Variant", cp, ""))
    group = ""
    for line in data["emoji-test.txt"].splitlines():
        if line.startswith("# group: "):
            group = line.removeprefix("# group: ")
            continue
        match = re.search(r"^([A-F0-9 ]+)\s*;\s*(fully-qualified|minimally-qualified|unqualified|component)\s*#\s*\S+\s+E[\d.]+\s+(.+)$", line)
        if not match:
            continue
        raw, status, title = match.groups()
        key = code_key(raw)
        cp = int(key.split()[0], 16)
        aliases[key].append(title)
        if title.startswith("flag: "):
            aliases[key].append(title[6:])
        if key in entries:
            base = entries[key]
            entries[key] = (*base[:6], group if status in {"fully-qualified", "component"} else base[6])
        elif status in {"fully-qualified", "component"}:
            entries[key] = (key, localized_names.get(key, title), block(cp, "Other"), "Common", "Emoji", cp, group)

    with sqlite3.connect(output) as db:
        db.executescript("""
          PRAGMA journal_mode=OFF;
          PRAGMA synchronous=OFF;
          CREATE TABLE entry (id INTEGER PRIMARY KEY, scalars TEXT UNIQUE, name TEXT NOT NULL,
              block TEXT NOT NULL, script TEXT NOT NULL, category TEXT NOT NULL, point INTEGER NOT NULL, emoji TEXT NOT NULL);
          CREATE VIRTUAL TABLE lookup USING fts5(words, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');
          CREATE TABLE entity (name TEXT PRIMARY KEY, scalars TEXT NOT NULL);
          CREATE INDEX entity_scalars ON entity(scalars);
          CREATE TABLE metadata (name TEXT PRIMARY KEY, version TEXT NOT NULL);
        """)
        ordered = sorted(entries.values(), key=lambda row: (row[5], len(row[0]), row[0]))
        db.executemany("INSERT INTO entry VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       ((index, *entry) for index, entry in enumerate(ordered, 1)))
        db.executemany("INSERT INTO lookup(rowid, words) VALUES (?, ?)",
                       ((index, " ".join([item[1], item[2], item[3], item[6], *aliases[item[0]]]))
                        for index, item in enumerate(ordered, 1)))
        db.executemany("INSERT INTO entity VALUES (?, ?)",
                       ((name, key_for(value["characters"])) for name, value in json.loads(data["entities.json"]).items() if name.endswith(";")))
        db.executemany("INSERT INTO metadata VALUES (?, ?)", [("Unicode", "18.0.0"), ("Emoji", "18.0"), ("CLDR", "49")])
        db.execute("CREATE INDEX entry_point ON entry(point)")
        db.execute("CREATE INDEX entry_emoji ON entry(emoji)")
        db.execute("INSERT INTO lookup(lookup) VALUES ('optimize')")
    print(f"Built offline catalog with {len(entries):,} entries", flush=True)

if __name__ == "__main__":
    source, output = Path(sys.argv[1]) / "catalog-source.zip", Path(sys.argv[2])
    pending_output = output.with_suffix(".tmp")
    pending_output.unlink(missing_ok=True)
    build(source, pending_output)
    pending_output.replace(output)

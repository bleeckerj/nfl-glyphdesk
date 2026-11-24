"""Package the pinned upstream inputs needed for an offline build."""
import hashlib
import json
from pathlib import Path
import sys
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)
ucd = ("UnicodeData.txt", "Blocks.txt", "Scripts.txt", "NameAliases.txt", "NamedSequences.txt",
       "StandardizedVariants.txt", "emoji/emoji-variation-sequences.txt")
files = {}
with ZipFile(source / "UCD.zip") as archive:
    for name in ucd:
        files[name] = archive.read(name)
with ZipFile(source / "Unihan.zip") as archive:
    data = archive.read("Unihan_Readings.txt").splitlines()
    files["Unihan-readings.txt"] = b"\n".join(line for line in data if b"\tkDefinition\t" in line or b"\tkMandarin\t" in line)
with ZipFile(source / "core.zip") as archive:
    for locale in ("en", "de", "fr", "es"):
        for folder in ("annotations", "annotationsDerived"):
            files[f"{folder}/{locale}.xml"] = archive.read(f"common/{folder}/{locale}.xml")
for name in ("emoji-test.txt", "entities.json", "unicode-license.txt"):
    files[name] = (source / name).read_bytes()
with ZipFile(destination / "catalog-source.zip", "w", compression=ZIP_DEFLATED, compresslevel=9) as result:
    for name, data in sorted(files.items()):
        result.writestr(ZipInfo(name, (2026, 1, 1, 0, 0, 0)), data, compress_type=ZIP_DEFLATED, compresslevel=9)
manifest = {item.name: hashlib.sha256(item.read_bytes()).hexdigest() for item in sorted(source.iterdir()) if item.is_file()}
(destination / "upstream-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")

#!/bin/zsh
set -eu
if (( $# != 1 )); then
    print -u2 "Pass a Glyph Desk search query as the script argument."
    exit 2
fi
exec /Applications/GlyphDesk.app/Contents/Helpers/glyphdesk lookup --first -- "$1"

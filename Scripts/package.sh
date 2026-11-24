#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Build .build
xcodebuild -project GlyphDesk.xcodeproj -scheme GlyphDesk -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath .build/Release \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO -quiet build
app=".build/Release/Build/Products/Release/GlyphDesk.app"
codesign --verify --deep --strict "$app"
for binary in "$app/Contents/MacOS/GlyphDesk" "$app/Contents/Helpers/glyphdesk"; do
    slices="$(lipo -archs "$binary")"
    for architecture in arm64 x86_64; do
        if [[ " $slices " != *" $architecture "* ]]; then
            printf 'Missing %s in %s
' "$architecture" "$binary" >&2
            exit 1
        fi
    done
done
ditto -c -k --keepParent "$app" Build/GlyphDesk.zip
printf 'Created %s/Build/GlyphDesk.zip\n' "$PWD"

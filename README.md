# Glyph Desk

Glyph Desk is a private macOS character and font utility for macOS 13 or later. The menu bar palette finds Unicode characters by name, alias, code, emoji keyword, or drawing. The workspace adds installed-font coverage, comparison, editable proofs, font metadata, and print or PDF output.

## Development

The project root is /Users/julian/Code/nfl-popchar. Open GlyphDesk.xcodeproj and choose the shared GlyphDesk scheme. The checked-in Xcode project builds the bundled SQLite catalog without a network connection.

Run these commands from the project root.

    xcodebuild -project GlyphDesk.xcodeproj -scheme GlyphDesk -destination 'platform=macOS' -derivedDataPath .build/Derived test
    Scripts/package.sh

Use XcodeGen only when changing the project specification or adding source files. The package script writes the universal, ad hoc signed app archive to Build/GlyphDesk.zip. Move GlyphDesk.app to Applications and open it. Use Control–Option–Space or the menu bar icon to bring up the palette.

Open Settings to grant Accessibility permission for direct insertion. On Macs with clipboard privacy controls, allow pasteboard access for rich text and pictures. Copy is available regardless of Accessibility permission.

The bundled helper supports offline lookup from Terminal or a Typinator script asset.

    /Applications/GlyphDesk.app/Contents/Helpers/glyphdesk lookup --first 'rightwards arrow'
    /Applications/GlyphDesk.app/Contents/Helpers/glyphdesk lookup --json 'flag Canada'

Add Scripts/GlyphDesk-Typinator.sh to Typinator’s Assets and pass the lookup text as a script argument. The wrapper expects GlyphDesk.app in Applications.

## Reference data

Data/Reference/catalog-source.zip contains the pinned build inputs from Unicode 18.0.0, Emoji 18.0, CLDR 49, Unihan, and WHATWG named character references. The archive includes the Unicode data license. The WHATWG data is attributed to the [WHATWG HTML Standard](https://html.spec.whatwg.org/multipage/named-characters.html). The SHA-256 manifest identifies the upstream downloads used to produce the compact input bundle.

Font metrics, outlines, glyph data, and supported languages come from fonts installed on the Mac. System symbols use the rendering resources supplied by macOS.

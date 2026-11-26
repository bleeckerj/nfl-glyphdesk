# Glyph Desk font review plan

## Summary

Build the five features in the requested order **2 → 4 → 5 → 3 → 1**. Start with a saved project that holds specimen text and a font shortlist. Use that project for typographic controls, font-file review, and coverage reports. Finish with persistent windows.

## Implementation order

1. **Feature 2 — Saved font shortlists and proof text.** Add a **Project Proof** mode to the Proof workspace. Users can create and reopen named projects, add or reorder candidate faces, and save named text samples such as *Title* and *Body*. Show the active sample side by side across the shortlist with shared controls for point size, text width, and line spacing. Save projects atomically in Glyph Desk’s local Application Support folder, and show when a saved face needs relinking. Use a shared Core Text layout for the project preview and its later PDF export.

2. **Feature 4 — Variable-font axes and OpenType features.** Add controls per candidate for available axes such as weight, width, and optical size. Offer supported OpenType features such as ligatures, small caps, tabular figures, and stylistic sets. Start with the font’s defaults, provide a reset, and save overrides with the candidate. Apply both kinds of settings to the same resolved face used in the proof. [Apple’s variation axes](https://developer.apple.com/documentation/coretext/ctfontcopyvariationaxes%28_%3A%29) · [Core Text feature settings](https://developer.apple.com/documentation/coretext/kctfontfeaturesettingsattribute)

3. **Feature 5 — Review font files before installing them.** Let users open `.otf`, `.ttf`, and `.ttc` files from Project Proof and choose a face from a collection. Preview directly from the file’s descriptor and save a file reference with the selected face. Show version, foundry, license URL when present, and matching installed faces by PostScript name. Distinguish same-name files by source and version, and provide **Relink** for missing or moved files. Add a project proof PDF and a shortlist metadata CSV. [Apple’s file-based font preview guidance](https://developer.apple.com/documentation/technologyoverviews/managing-the-fonts-for-your-app)

4. **Feature 3 — Coverage checks on real project text.** Analyze each saved sample across the shortlist using the same shaped text and font settings as the proof. Mark each text cluster as **Native**, **Fallback**, or **Missing** and name the actual fallback face. Show totals per candidate, highlight problem text in context, and let users filter to faces that render the whole sample natively. Add the coverage results to the project PDF and CSV. [Core Text glyph-to-string mapping](https://developer.apple.com/documentation/coretext/ctrungetstringindices%28_%3A_%3A_%3A%29)

5. **Feature 1 — Persistent workspace and compact palette.** Keep both views open across app switches and outside clicks, preserving their position, search, selection, and active project. Add a saved **Float above other windows** control, on by default for the compact palette and off for the workspace. Keep after-insertion dismissal independent. Update the displayed destination as the user moves between apps, verify the focused field before pasting, and offer **Copy** if the destination can’t be verified. Successful insertion leaves keyboard focus in the destination app.

## Acceptance checks

- **Project proof.** Save a project with two samples and three faces, relaunch, and verify the shortlist order, text, and layout settings.
- **Typography controls.** Change a known variable axis and an OpenType feature, verify each visible effect, then reopen and reset the proof. Check that a static font offers only controls it supports.
- **Font-file review.** Preview an uninstalled font and a multi-face collection, distinguish a same-name installed face, and exercise relinking. Open both exports and verify their contents against the project.
- **Coverage.** Verify native rendering, fallback, and missing glyphs with accented names, combining marks, ligatures, right-to-left text, and emoji sequences. Confirm the screen, PDF, and CSV agree.
- **Window behavior.** Switch between two apps with each Glyph Desk view open. Verify that the window and selection persist, floating works independently, and insertion reaches only the verified destination. Test both after-insertion settings and the Copy fallback.

## Defaults and rollout

Keep project data local and support macOS 13 or later. Existing preferences should load with backwards-compatible defaults. Build and run the relevant Xcode tests after each phase, then verify the complete workflow in the native app.

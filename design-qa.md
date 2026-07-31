# Onboarding Design QA

final result: passed

## Comparison target

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019fb3f7-cc0f-7d90-b7bd-a0885f88ba84/exec-605b1ca7-d429-4829-a3d7-4a39b79ad9b0.png`
- Final implementation screenshot: `/Users/gaoyuan/.codex/visualizations/2026/07/31/ndm-onboarding-v2/05-empty-focus-final.png`
- Native window viewport: 620 x 528 pt including title bar; light appearance; Simplified Chinese; key window; empty input focused.
- Source pixels: 1360 x 1156. Implementation capture: 1464 x 1280, including the macOS window shadow around a Retina 620 x 528 pt window.
- Density normalization: the source is a generated presentation capture rather than a native-density artifact. Comparison used the full visible window in both artifacts, aligned by the window frame and judged by proportional layout, hierarchy, and optical scale rather than raw pixel coordinates. The implementation was also checked at its native Retina capture density.

## Full-view comparison evidence

The source and each implementation capture were opened together in one comparison input. The final pass checked the same empty, focused, light-mode state. The native implementation preserves the source's single-task hierarchy: NDM mark, promise, explanation, focused link field, one dominant action, quiet inbox escape hatch, recognizable source preview, and trust footer.

## Required fidelity surfaces

- Fonts and typography: native San Francisco is used throughout. The bold 25 pt promise, secondary explanatory copy, semibold action labels, and quiet footer preserve the source hierarchy without truncation or awkward wrapping.
- Spacing and layout rhythm: the actionable column was reduced to 420 pt, the input to 44 pt, the preview wordmark was optically reduced, and row/footer separators were restored. The result matches the source's centered, compact vertical cadence with no clipped persistent controls.
- Colors and visual tokens: system label colors and NDM's existing accent token map to the source's white/gray/blue palette. The focused field now has a visible system-blue 1.5 pt border, and invalid input switches to semantic red.
- Image quality and asset fidelity: the generated NDM onboarding mark is used as a real 512 x 512 PNG asset, not a code-drawn substitute. The existing YouTube wordmark asset is used for the preview row and remains sharp at Retina density.
- Copy and content: the promise and helper copy match the selected concept. The sample row intentionally uses source-recognition language instead of a fabricated remote video title or duration, while preserving the same information hierarchy.
- Interaction and accessibility: the text field, clear action, Return primary action, Escape inbox action, example preview, inline error, and link handoff were exercised. Controls expose accessibility labels/help, and the focus indicator is visible.

## Focused-region evidence

No separate crop was required because the final 1464 x 1280 Retina capture renders the input border, brand marks, type weights, separators, and footer text clearly at inspection scale. Interaction-specific full-window evidence was captured separately:

- Invalid input: `/Users/gaoyuan/.codex/visualizations/2026/07/31/ndm-onboarding-v2/07-invalid-error.png`
- Recognized direct link: `/Users/gaoyuan/.codex/visualizations/2026/07/31/ndm-onboarding-v2/09-link-ready.png`
- New Download handoff: `/Users/gaoyuan/.codex/visualizations/2026/07/31/ndm-onboarding-v2/10-new-download-handoff.png`

## Comparison history

### Iteration 1 — blocked

- P2 focus fidelity: the field was keyboard-focused but the shell retained a gray border.
- P2 preview hierarchy: the YouTube wordmark was too large and the row felt visually top-heavy.
- P2 structure: the missing lower preview/footer separators made the lower half read as accidental whitespace.

Fixes: made focus styling update the layer immediately, used a full system-blue focused border, narrowed the content column, reduced the wordmark slot, added the preview bottom separator, and added the full-width footer separator.

### Iteration 2 — blocked

- The content width and preview proportions were corrected, but the focus border still did not persist after the field editor became first responder.

Fix: reordered first-responder setup and focus-state assignment, then derived end-editing focus from the active field editor.

### Final pass — passed

Post-fix evidence: `/Users/gaoyuan/.codex/visualizations/2026/07/31/ndm-onboarding-v2/05-empty-focus-final.png`.

No actionable P0, P1, or P2 visual differences remain. The native AppKit button keeps its subtle system material/gradient instead of flattening to a mock-only fill; this is an acceptable platform-native P3 variation.

## Implementation checklist

- [x] Single-screen native welcome flow
- [x] Real NDM and site-brand assets
- [x] Focus, invalid, recognized-link, clear, keyboard, and direct-inbox states
- [x] Existing New Download handoff with original input preserved
- [x] Retina screenshot comparison against the selected source
- [x] P0/P1/P2 issues fixed and re-captured

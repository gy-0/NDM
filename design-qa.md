# Design QA — NDM third-concept chrome and inspector artifact

## Comparison target

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Final DMG screenshots:
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/inspector-dmg-light-100.png`
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/inspector-dmg-dark-140-final.png`
- State: macOS light 100% and dark 140% semantic scale, completed Tencent Video DMG selected. Both the approved source and current AppKit implementation were opened together for comparison.

## Findings

No actionable P0, P1, or P2 findings remain.

- Inspector artifact: one oversized lower-right arc and exactly one decorative type poster. There is no duplicated thumbnail, play glyph, button chrome, or hit target.
- Perspective treatment: every type poster uses stable draw-space rotation and horizontal skew, producing the flat angled-watermark effect from the approved concept rather than a literal preview card.
- File-type behavior: real thumbnails stay in the small information header only. Video, image, DMG, app, package, archive, audio, document and generic states all use an extension-appropriate SF Symbol in the ambient area. DMG uses a cool external-drive mark rather than an enlarged Finder file icon.
- Hierarchy and chrome: the in-content toolbar is 62 pt high, with 38 pt tool chips and a 36 pt search capsule. The sidebar uses a 215–268 pt navigation rail, 40 pt base rows and damped semantic zoom. The cool neutral toolbar, selected blue pill and wider navigation rhythm follow the approved third concept.
- Sidebar taxonomy: `应用` now uses a package glyph, avoiding both the unexplained rounded-square/grid metaphor and the misleading `⌘` command mark. DMG/ISO rows use a disk-image glyph instead of being misclassified visually as orange archives. `其他` remains available for uncategorized files.
- Accessibility: the lower-right artwork is decorative and absent from the accessibility tree. The three real actions remain exposed and labelled, including `在访达中显示`.
- Scaling and clipping: the inspector keeps a 360–450 pt preferred width and its full action labels remain readable at 140%; the artifact scales gently and is clipped only at the lower-right window edge to reproduce the reference composition.
- Long-name resilience: at 140% the inspector keeps the filename to one line and truncates through the middle, preserving both the recognizable stem and `.dmg` extension instead of leaving an orphaned suffix on a second line.

## Comparison history

1. P1 — video state contained a duplicated preview plus a play affordance that did not play. Fixed by keeping the real cover only in the header and making the ambient layer a non-interactive film-type poster.
2. P2 — the initial replacement enlarged the raw DMG Finder icon and the angle was not visibly stable. Fixed by using a flat external-drive symbol and moving rotation/skew into draw space.
3. P2 — toolbar, search, sidebar width and row rhythm still read as default AppKit chrome. Fixed with shared chrome tokens, a 62 pt toolbar, 38 pt tool chips, a custom search shell and a 215–268 pt sidebar.
4. P2 — the application category's four-square mark still looked like an unexplained rounded rectangle. A later `⌘` replacement read as keyboard/terminal semantics. The final state uses `shippingbox`, which matches downloaded installers and app packages.
5. Final comparison — video shows one real header cover plus one clearly angled film mark, with no false interaction. The selected DMG state bypasses Quick Look artwork by construction and uses its own tilted drive mark inside the same oversized arc.

## Runtime checks

- Switched between a completed video and completed DMG in the running preview; inspector content and artwork updated correctly.
- Confirmed only `打开`, `在访达中显示`, and `复制链接` are interactive in the inspector action rail.
- Confirmed in accessibility output and screenshots that `应用` exposes a package icon, selected DMG rows expose an external-drive icon, and uncategorized items remain under `其他`.
- Video and DMG states were captured from a Debug-only isolated QA app. The QA instance used its own `/tmp` database, bridge port, appearance, language and scale; it never read the user's running preview data or clipboard.
- Build succeeded. All 176 deterministic/local tests passed (74 engine, 98 core, 4 bridge); four live YouTube network checks were intentionally excluded.

final result: passed

---

## Space Confidence — quality and collection sheet

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Target viewport: 480 × 584 pt single-video sheet and 480 × 662 pt collection sheet.
- Target states: comfortable, tight, insufficient and unknown size; single video and whole collection; Chinese/English; light/dark.
- Implementation screenshot: unavailable because macOS remained locked during both runtime capture attempts.

### Evidence available

- The quality sheet adds one flat status row between quality options and media options. It reuses the established semantic icon, compact typography and single blue primary action; no warning card or technical file-system copy was introduced.
- Single-video estimates distinguish progressive media from separately downloaded video/audio that need a merge workspace.
- Collection estimates project total final size from item durations while budgeting only one temporary merge workspace because collection entries run sequentially.
- The same budget is enforced immediately before media task creation. Ordinary segmented files now wait for a real remote size probe, then check temporary segments and final-file coexistence before payload transfer; resume bytes, an existing destination file and cross-volume destinations are handled separately.
- 159 deterministic/local tests pass: 69 engine, 86 core and 4 browser bridge. Four live YouTube network checks remain intentionally outside this run.

### Required fidelity surfaces

- Fonts and typography: code uses the existing 11.5 pt medium status style, but wrapping and optical weight are not visually proven.
- Spacing and layout rhythm: the row is constrained to at least 24 pt with an 8 pt icon gap; full sheet height and collection wrapping are not visually proven.
- Colors and visual tokens: semantic green/orange/red plus secondary text reuse existing tokens; light/dark resolution is not visually proven.
- Image quality and icon fidelity: only SF Symbols are used; no placeholder or generated asset is involved. Actual scale and baseline are not visually proven.
- Copy and content: Chinese and English actionable strings are covered by localization tests; runtime truncation is not visually proven.

### Findings

- [P1] Runtime appearance and layout evidence is missing.
  - Location: Space Confidence row in the single-video and collection quality sheets.
  - Evidence: build and behavior tests pass, but the Mac lock screen prevented capturing either implementation state and therefore prevented a same-input comparison with the source.
  - Impact: sheet height, wrapping, dark-mode contrast and disabled-primary-action appearance cannot be accepted from code alone.
  - Fix: after unlock, relaunch the rebuilt preview, capture light Chinese and dark English states at the target viewports, then open each capture beside the source and resolve any P1/P2 drift.

### Comparison history

1. First runtime attempt: blocked by the locked Mac; no visual conclusion was inferred.
2. The implementation and full local regression suite were completed while waiting; the second runtime attempt was still blocked by the same lock state.

final result: blocked

---

## Magic Inbox — copied share text to Link Lens

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Target state: copy a fresh Douyin/Xiaohongshu/Bilibili/YouTube/TikTok share command in another app, return to NDM, and see one borderless source-aware action in the approved toolbar whitespace; clicking it opens the existing Link Lens.
- Implementation screenshots:
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/magic-inbox-dark-080.png`
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/magic-inbox-dark-100.png`
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/magic-inbox-light-140-isolated.png`
- Destination Link Lens screenshot: `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/magic-inbox-link-lens-light.jpeg`
- Runtime states: dark Chinese 0.8× and 1.0×, plus light Chinese 1.4×. Each state used a standalone QA bundle, isolated support directory and unique bridge port.

### Evidence available

- Clipboard discovery is again wired to the setting that already existed. It reads only local text, only when the app becomes active or the setting changes, and only once for each pasteboard `changeCount`.
- Share text and scheme-less known short links use the same resolver as paste and drag/drop. TikTok now has first-class source identity rather than falling back to a generic web link.
- Unrelated text and conservatively recognized duplicate tasks produce no offer. Disabling clipboard discovery removes a visible candidate immediately; re-enabling reevaluates the current clipboard.
- The action occupies existing toolbar whitespace without adding a card, badge or notification. It is borderless at rest and uses a standard SF Symbol; click opens Link Lens instead of starting an unreviewed download.
- Toolbar typography, icons and intrinsic button widths now participate in semantic zoom while the 62pt chrome and overall window geometry stay stable.
- Three focused Magic Inbox tests and bilingual copy assertions pass. The complete local suite passes 176 tests: 74 engine, 98 core and 4 browser bridge. Four live YouTube network checks remain excluded.
- The approved source plus dark 0.8×, dark 1.0× and light 1.4× implementations were opened in one comparison input. The clipboard action remains fully readable between Resume and Search at every scale, preserves the source toolbar rhythm, and adds no new container surface.
- A separate focused crop was unnecessary because the temporary action, adjacent tools and search field are all clearly readable at native capture scale. The Link Lens destination was captured separately with a real Bilibili clipboard URL and retained first-responder focus in the URL field.

### Findings

No actionable P0, P1 or P2 findings remain in the inspected states.

- Dark dynamic colors keep the candidate legible without creating a new pill/card surface.
- 0.8×, 1.0× and 1.4× keep the candidate, tools and search field on one line; nothing overlaps or escapes its control bounds.
- Semantic zoom changes typography and intrinsic control widths, not the window coordinate system or split-view geometry.
- Full regression remains 176 passing local tests; the four live YouTube network checks are intentionally outside this run.

final result: passed

---

## Already Here — duplicate recognition in Link Lens

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Light Chinese capture: `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/duplicate-lens-light-final.png`
- Dark English capture: `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/duplicate-lens-dark-final.png`
- Viewport: 520 × 382 pt New Download sheet.

### Runtime verification

- An existing YouTube item is recognized before a new task is created. The resolved title, cover, duration, quality count and subtitle count remain visible; duplicate state is one quiet blue status line rather than another warning card.
- `查看现有 / View existing` closes the sheet, clears any task search/filter, selects the newest useful matching task, scrolls it into view and restores its Inspector.
- `再下载一份 / Download again` deliberately continues to the normal quality sheet; it does not silently block a legitimate re-download.
- Active or queued matches are preferred over completed matches, then the newest task wins. Failed or paused history remains discoverable when it is the only match.
- Source, light Chinese and dark English captures were inspected together. The flow preserves the approved concept's compact hierarchy, restrained cool-neutral surfaces and single blue primary action.

### Findings

No actionable P0, P1 or P2 findings remain.

- Three actions fit without clipping at the default semantic scale. Cancel and View existing remain quiet; Download again is the only filled action.
- Dark appearance uses the same appearance-aware Link Lens surface fixed during Collection Lens QA; status and button contrast remain readable.
- The full suite passes 149 tests with zero failures. The excluded live YouTube sample download remains an external destructive/network check; live format and playlist probes pass.

final result: passed

---

## Collection Lens — playlist and collection flow

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Target states: recognized collection in Link Lens; `当前视频 / 整个合集` scope rail in the quality sheet; Chinese/English and light/dark appearance.
- Implementation screenshots:
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/collection-lens-light-final.png`
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/collection-lens-dark-final.png`
  - `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/collection-scope-light-final.png`

### Evidence available

- A live 20-item YouTube playlist resolves as a collection and yields portable item URLs; a pure playlist link now reaches a playable primary-item probe in about four seconds instead of the original roughly 52-second path.
- Whole-collection selection creates independent numbered tasks and stores the selected quality/container/subtitle choices on each task.
- Queue scheduling is deliberately one media item at a time even when a task uses 32 fragment connections, avoiding a collection multiplying into hundreds of simultaneous sockets.
- Failed items do not block later items, and the oldest waiting collection item is resumed first after completion or app relaunch. A regression test covers the store's newest-first row order so collections cannot download backwards.
- Exact declared collection counts no longer incorrectly show `前 N 项 / First N items`; unknown collections hitting the safety cap still disclose truncation.
- Full suite: 144 tests passed with zero failures. The destructive live sample download remains excluded; live format, collection and pure-playlist preflight probes passed.

### Runtime verification

- A pure playlist URL resolved to its real title and 20-item count in both Chinese and English without layout shift.
- The scope selector renders as one flat segmented rail. It does not introduce another pair of cards or expose command-line terminology.
- Switching to the whole collection updates the single blue action to `下载 20 项 · 1080p · MP4`; the queue explanation and localized count remain unclipped.
- Light Chinese, dark English and the scope state were opened beside the approved third-concept source in the same comparison input. The cool-neutral surfaces, compact hierarchy and single-accent treatment remain consistent with the source.

### Findings

No actionable P0, P1 or P2 findings remain in the inspected states.

- The first dark-mode capture exposed a light Link Lens surface with washed-out semantic text. The layer had snapshotted `controlBackgroundColor` while the app was light. `LinkLensView` now resolves semantic layer colors through `updateLayer()` whenever the effective appearance changes; the rebuilt dark capture confirms a continuous dark surface and readable text.
- Queue order initially followed the store's newest-first row order and would have downloaded a collection backwards. Scheduling now selects the oldest waiting collection task, with regression coverage.

final result: passed

---

## Link Lens — New Download entry flow

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Viewport: 520 × 382 pt New Download sheet, macOS light appearance
- State: YouTube link pasted; immediate identity, recognizing, resolved preview and Continue transitions
- Implementation screenshots: the light and dark Collection Lens captures above exercise the same Link Lens component with real resolved metadata.

### Evidence available

- Build succeeds with the new sheet and shared engine store.
- The media probe integration test resolves a live YouTube sample and returns four quality tiers.
- Four focused Link Lens tests pass: concurrent probe deduplication, original/resolved short-link cache aliasing, non-sticky failure retry, and media-page/direct-file classification.
- Full interaction was exercised in the running preview, including immediate identity, resolved metadata, Continue, language switching and appearance switching.

### Runtime verification

- A real YouTube URL showed site identity immediately and transitioned to title, cover, duration, quality count and subtitle count without a play affordance.
- Continue opened the prepared quality sheet without a second metadata delay.
- Chinese and English copies fit the 520 × 382 pt sheet. System language was changed from English back to Chinese and the reopened Settings window also rebuilt in Chinese, confirming the reported stale-language bug is fixed.
- Light and dark states were visually inspected. The only appearance defect found was the snapshotted Link Lens surface described above; the rebuilt capture passed.

### Findings

No actionable P0, P1 or P2 findings remain.

### Focused-region comparison

The source and final light/dark Link Lens captures were inspected together. The implementation keeps the source's restrained cool-neutral palette, strong information hierarchy, compact Finder-like type and one blue primary action while fitting the narrower task-focused sheet.

### Comparison history

1. Initial QA attempt: preview built and launched; Computer Use returned `The Mac is locked and automatic unlock could not unlock it`. No visual findings were inferred from code.
2. After unlock: light Chinese, English, dark appearance and the collection scope state were captured from the running preview.
3. P1 — dark Link Lens retained a light cached surface and reduced text contrast. Fixed with appearance-aware layer updates and verified after rebuild.

final result: passed

---

## Delivery Recipes completion page

- Reference: the same approved third-concept visual above.
- Runtime screenshot: /Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/delivery-recipes-final.png
- State: completed YouTube video with one matching subtitle; Original recipe selected.

The completed result page keeps the established cool-neutral palette, one blue primary action, compact Finder-like typography and flat separators. Delivery Recipes use a single four-way rail rather than four cards or a button grid. The selected result changes one icon, one outcome sentence and one contextual action. “Original always kept” remains visible across all recipes.

Runtime QA found and fixed two product issues:

1. Original initially repeated “Show in Finder” inside the recipe section even though the page already had that action. The duplicate CTA is now removed.
2. Completed tasks could not reopen their result page after the first completion moment. The context menu now exposes “Result Details / 成果详情”, restoring subtitles and Delivery Recipes at any time.

Chinese copy for Original, Mobile, Audio and WeChat fits at the default semantic scale without truncation. The recipe engine was separately exercised with real generated media; Mobile and Audio outputs were created, a second export received a collision-safe numbered name, and subtitle filenames followed the generated video stem.

final result: passed

---

## Link Rescue — expired browser-authorized downloads

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Target state: a failed direct-media task with an expired-link diagnostic selected in the list and Inspector; Renew opens its source page; the next browser capture resumes the same task.
- Implementation screenshot: unavailable because macOS remained locked.

### Evidence available

- A same-page browser capture carrying fresh URL, Cookie, Referer and User-Agent updates the original failed task rather than inserting a duplicate.
- The task id, original destination filename and existing `seg.xN` partial files are preserved. Completed video retry remains a true forced re-download.
- Automatic reassociation is restricted to structured `linkExpired` and `signInRequired` failures. Disk-full and unrelated failures do not qualify.
- Dual-track media require both fresh video and audio URLs, preventing mixed authorization generations.
- Main-window and progress-window Renew actions open the stored source page when the task is browser-rescuable; tasks without a reliable source page retain the manual URL field.
- 163 deterministic/local tests pass: 72 engine, 87 core and 4 browser bridge. Four live YouTube network checks remain outside this run.

### Findings

- [P1] Runtime action and copy are not visually proven.
  - Evidence: behavior and persistence tests pass, but the locked Mac prevents checking the selected-row copy, Inspector button emphasis, source-page action and post-capture transition in a real window.
  - Fix: after unlock, relaunch the rebuilt preview, exercise one synthetic expired task through browser recapture, and compare the selected row/Inspector against the approved source in the same input.

final result: blocked

---

## Preference Memory — site-level delivery choices

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Target state: choose a non-default quality, MKV and an available subtitle for one site; reopen a second video from the same site and see those controls restored without any new card, badge or settings surface.
- Implementation screenshot: unavailable because macOS remained locked.

### Evidence available

- Preferences are written only when the user starts a download, so exploratory clicks are not learned.
- YouTube/youtu.be, Bilibili/b23.tv, Douyin, Xiaohongshu and TikTok host families are normalized; unrelated sites remain isolated.
- The stored payload contains only the canonical site key, height tier, MP4/MKV and optional subtitle code. It cannot encode page URLs, titles, cookies or content IDs.
- Exact available choices restore; a missing height returns to the first recommended tier and a missing subtitle turns subtitles off.
- Five focused preference tests pass. The complete local suite passes 168 tests: 72 engine, 92 core and 4 browser bridge. Four live YouTube network checks remain excluded.

### Findings

- [P2] Silent restoration is not yet proven in the rendered sheet.
  - Evidence: the picker builds and the persistence/resolution layer is covered, but the locked Mac prevents opening two same-site videos and confirming the restored radio row, container popup, subtitle popup, button copy and storage estimate together.
  - Fix: after unlock, make one non-default choice, reopen another URL from the same site, capture the restored light and dark states, then compare both with the approved source in the same input.

final result: blocked

---

## Continuity Progress — one journey from transfer to ready file

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Target state: a separated video/audio download with subtitles, observed through transfer, merge, subtitle preparation and final ready state in the list, Inspector, progress window and Dock.
- Implementation screenshot: unavailable because macOS remained locked.

### Evidence available

- `DownloadProgress` now keeps truthful transferred bytes separate from one end-to-end `journeyFraction`; ordinary HTTP/FTP/HLS tasks retain their byte-derived fraction.
- Media transfer occupies 0–96%; structured yt-dlp postprocessor events advance merger, subtitle and final-file stages to 97.2%, 98.5% and 99.2%; successful final-file discovery alone advances to 100%.
- Video/audio components remain aggregated by stable format id, so a second stream cannot reset the overall journey. Total revisions cannot move the journey backward.
- The blue main strip, green unified strip, task-list row, Inspector, menu-bar task and Dock aggregate all consume `fractionCompleted`. The downloaded-byte detail independently shows its truthful byte percentage.
- Progress copy now distinguishes “Downloading video and audio”, “Combining video and audio”, “Preparing subtitles” and the generic final-file step in Chinese and English.
- Fourteen focused media-progress tests pass, including postprocessor parsing, exact bytes during postprocessing and monotonic staged progression. The complete local suite passes 171 tests: 74 engine, 93 core and 4 browser bridge. Four live YouTube network checks remain excluded.

### Findings

- [P1] The real cross-surface animation and stage timing are not visually proven.
  - Evidence: state transitions and all consumers compile and pass deterministic tests, but the locked Mac prevents watching one actual separated-stream download and confirming that both bars, the hero percentage, list copy, Inspector and Dock move together without clipping or stale phase text.
  - Fix: after unlock, run one short 1080p video with subtitles, capture transfer/merge/subtitle/complete states in light and dark appearance, and compare the progress window plus main-window rows with the approved source in the same input.

final result: blocked

---

## Current build gate

All earlier captured milestones remain passed. Magic Inbox now has a real 1.4× light runtime capture and same-input source comparison. Space Confidence, Link Rescue, Preference Memory, Continuity Progress, Ready Choice and the remaining Magic Inbox appearance/scale states still need their specific rendered comparisons.

final result: blocked

---

## Tail balance + bounded inspector artifact — 2026-07-17

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Isolated runtime: `/tmp/NDMMagicQA.app`
- Dark 1.4× DMG capture: `/var/folders/28/7yq61yhd23sb8zz0ynmnsz500000gn/T/codex-shot-2026-07-17_21-44-38.png`
- Dark 1.4× video capture: `/var/folders/28/7yq61yhd23sb8zz0ynmnsz500000gn/T/codex-shot-2026-07-17_21-48-59.png`
- Same-input source comparison: `/Users/gaoyuan/.codex/visualizations/2026/07/17/019f6eb2-7649-7a61-b999-2d4666a4f791/reference-vs-tail-art-dark-140.png`

### Findings

- The oversized lower-right arc is gone. DMG and video type marks remain fully inside measured safe margins at 1.4×; no edge is clipped or pushed outside the inspector.
- Video uses a tilted `film` type mark with no play triangle and no repeated cover, so it does not promise click-to-play behavior.
- Full-bleed video rows no longer receive a dark outline when unselected. The selected row keeps its intentional selection treatment.
- Completion delivery now exposes only Original and Audio in the primary UI; Mobile and WeChat transcodes remain engine-compatible but are not core product choices.
- The local 8 MiB straggler integration fixture proves that the engine issues fresh tail Ranges, preserves every prefix, merges byte-identically, and records `TailBalance:`.
- 178 deterministic/local Swift tests pass after the change (75 engine, 99 core, 4 bridge); four live network-only media checks remain outside this gate.

final result: passed

---

## Ready Choice — exact one-click repeat download

- Source visual truth: `/Users/gaoyuan/.codex/generated_images/019f6eb2-7649-7a61-b999-2d4666a4f791/exec-4c4b7a12-f1af-4c27-8d4a-014ea1b70720.png`
- Intended implementation: `/tmp/NDMPreview.app`
- Target state: after one successful site-specific choice, paste a second single-video URL from the same site; Link Lens presents one blue “Download 1080p · MP4” action and one quiet “Options…” action.
- Implementation screenshot: unavailable because macOS remained locked.

### Evidence available

- The quick path is eligible only when the remembered height, container and optional subtitle exist exactly in the current probe. It never substitutes another quality or silently drops subtitles.
- Collections and duplicates never enter the quick path. Browser authorization can only be requested through the full recognition flow, so a page that still needs browser access cannot be mistaken for a ready choice.
- Space Confidence must be `comfortable`. Tight, insufficient and unknown capacity all keep the complete quality and storage sheet.
- The blue action calls the same `DownloadManager.startYtDlp` path as the full picker, including the second live storage guard, task insertion, thumbnail prefetch, unified progress and completion delivery.
- Chinese and English button interpolation is covered directly. The complete deterministic/local suite passes 172 tests: 74 engine, 94 core and 4 browser bridge. Four live YouTube network checks remain excluded.
- `/tmp/NDMPreview.app` has been rebuilt and its ad-hoc signature verifies strictly.

### Findings

- [P1] The one-primary/one-secondary composition and transition into progress are not visually proven.
  - Evidence: eligibility, copy, task creation and fallback paths compile and pass behavioral tests, but the locked Mac prevents comparing the rendered Link Lens button widths, spacing and keyboard focus with the approved third concept.
  - Fix: after unlock, create one remembered same-site preference, capture eligible and ineligible Link Lens states in light and dark appearance, click both the primary action and Options, and compare those states with the approved source in the same input.

final result: blocked

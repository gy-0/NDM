# NDM Relay

NDM Relay is the Chrome companion for NDM. It sends intentional downloads to the
Mac app and turns detected videos into a small, native-looking download control.
It is maintained by Yuan Gao. Its browser identity and local bridge endpoint are
NDM-specific, so it can coexist with the original Neat app and extension.
Required third-party notices remain in `LICENSE` and are not presented as the
current extension author.

## Safer download catching

- Only top-level download navigations are handed to NDM automatically.
- DAT/BIN responses, XHR traffic, hidden frames, and ordinary page subresources
  are not treated as user-requested downloads.
- If a hidden/subresource response still makes Chrome create a suspicious
  DAT/BIN/BLOB/MAP/PART/TMP download, NDM Relay cancels and removes that browser
  download. Explicit top-level opens and context-menu downloads remain allowed.
- A deliberately opened MP4 or attachment still goes to NDM.
- Right-click a link or image and choose **Download with NDM** when
  you explicitly want to send it to the app.

## Clearer video choices

- One clear **Choose quality and download** action is shown first.
- Duplicate qualities are collapsed and raw TS fragments are hidden.
- Other useful formats stay behind an **Other formats** disclosure.
- On X/Twitter, a native-looking **NDM** action is added to each video post.
- On YouTube watch pages, **Download with NDM** sits beside the existing video
  actions instead of floating over the player.
- On current Bilibili video pages, **NDM 下载** is part of the same toolbar row
  as like, coin, favorite, and share. The canonical BV/av page URL is sent to
  the Mac resolver.
- On current TikTok video pages, **Download with NDM** joins the page's action
  section and sends the canonical `@user/video/id` URL.
- Vimeo, Instagram, and Douyin have canonical page adapters and
  conservative inline insertion points. If a site changes its toolbar markup,
  NDM Relay leaves the page untouched instead of falling back to a permanent
  overlay; the generic media panel remains available on hover or from the
  toolbar button.
- Both site actions send a canonical page URL with the `media-page` route. The
  Mac app resolves the real video, opens its quality picker, and downloads the
  selected rendition; the raw page HTML is never treated as the file.
- X/Twitter page resolution suppresses raw TS transport responses, including
  large or unnumbered variants that would otherwise look like real choices.

The generic badge appears while the pointer is over detected media, then gets
completely out of the way. The NDM Relay toolbar icon shows a detected-media
count and restores the nearest panel on demand, so hiding the overlay never
makes the controls undiscoverable. Right-click the toolbar icon to pause or
resume ordinary browser download catching.

## Useful page resources

- Embedded PDF, Word, Excel, PowerPoint, CSV, EPUB/MOBI/AZW3, ZIP/RAR/7Z/TAR,
  DMG, and PKG responses appear in a compact **Page resources** shelf.
- Each row shows the real filename, type, size when known, and source host.
- Detection never starts a download. The URL is sent to NDM only after the user
  presses **Download**.
- Signed/range variants and strong filename/type/size mirrors of the same
  resource are collapsed. JavaScript, JSON,
  images, DAT/BIN traffic, and raw video transport fragments are excluded.
- The shelf minimizes to a persistent resource-count pill, and the NDM Relay
  toolbar button can open it again.

## Installation

Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and
select this `extension/NDMRelay` directory. Reload the extension after changing
its source files.

## Tests

```sh
node --test tests/*.test.js
node --check bg.js
node --check ct.js
node --check media-policy.js
node --check resource-policy.js
node --check resource-shelf.js
node --check site-adapters.js
```

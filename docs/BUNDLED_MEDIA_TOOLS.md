# Bundled media toolchain

Release builds must contain these standalone executables in
`NDM.app/Contents/Resources/Tools/`:

- `yt-dlp` — official macOS standalone release
- `ffmpeg` — redistributable macOS build with the required license notices
- `deno` — standalone JavaScript runtime used locally by modern video extractors

The application checks this private tool directory before any developer PATH.
Users must never be asked to install Homebrew, run commands, or download a
component after installing NDM. `Scripts/package-app.sh` refuses to produce a
release app if any tool is missing, which prevents accidentally shipping a build
whose core video feature only works on a developer machine.

## Reproducible preparation

```bash
Scripts/prepare-media-tools.sh
```

The preparation script downloads the checksum-published official macOS
standalone builds of yt-dlp and Deno. FFmpeg does not publish an official macOS
binary, so the script verifies the upstream release signature and signer
fingerprint, then builds an LGPL, static executable using only macOS system
frameworks. It rejects any nested tool with a non-system dynamic-library
dependency and collects the required license notices in `Vendor/Tools/Licenses`.

Pinned versions can be overridden by the release job through
`YTDLP_VERSION`, `DENO_VERSION`, and `FFMPEG_VERSION`. The checked-in defaults
are the versions last verified together; the large executables themselves are
ignored by Git.

## Release gate

```bash
NDM_OUTPUT_DIR=/tmp/ndm-release Scripts/package-app.sh
Scripts/verify-app-bundle.sh /tmp/ndm-release/NDM.app
```

Packaging writes a toolchain manifest with each component's version, SHA-256,
and architecture, signs every nested executable before signing the app, then
runs the verifier. Verification rejects missing notices, invalid signatures,
external dynamic-library dependencies, or any release that resolves a tool
from Homebrew/PATH. Its final check launches the app with an empty environment
and requires the headless report to return both `ready=true` and
`allBundled=true`.

Standalone Python applications do not automatically inherit macOS Keychain
trust. NDM therefore creates a local CA bridge from `/etc/ssl/cert.pem` and the
administrator-managed System keychain, points yt-dlp at that bundle, and keeps
HTTPS certificate validation enabled. This is required for users whose network
is intentionally mediated by a trusted local proxy; `--no-check-certificates`
is never used.

The release pipeline is responsible for notarizing the final bundle with the
real Developer ID credentials. Runtime tool downloads are intentionally avoided
so first use also works on restricted networks.

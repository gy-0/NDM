# Bundled media toolchain

Release builds must contain these standalone executables in
`NDM.app/Contents/Resources/Tools/`:

- `yt-dlp` — official unpackaged macOS runtime (`yt-dlp_macos.zip`, launcher plus `_internal/`). The onefile `yt-dlp_macos` binary is not used: it re-extracts on every launch and spends ~25s under Gatekeeper.
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

`NDM_MINIMUM_MACOS` defaults to `13.0` and is passed through both FFmpeg's
compiler and linker. Preparation fails if any resulting Mach-O slice declares a
newer minimum. The dependency-free FFmpeg build uses Apple's
`h264_videotoolbox` encoder (with software fallback enabled) for H.264 exports;
it intentionally does not claim the unavailable external `libx264` encoder.

## Release gate

```bash
NDM_OUTPUT_DIR=/tmp/ndm-release Scripts/package-app.sh
Scripts/verify-app-bundle.sh /tmp/ndm-release/NDM.app
```

Packaging writes a toolchain manifest with each component's version, SHA-256,
and architecture, signs every nested executable before signing the app, then
runs the verifier. Verification rejects missing notices, invalid signatures,
external dynamic-library dependencies, a nested executable whose Mach-O minimum
is newer than `LSMinimumSystemVersion`, or any release that resolves a tool from
Homebrew/PATH. Its final check launches the app with an empty environment and
requires the headless report to return both `ready=true` and `allBundled=true`.

Standalone Python applications do not automatically inherit macOS Keychain
trust. NDM therefore creates a local CA bridge from `/etc/ssl/cert.pem` and the
administrator-managed System keychain, points yt-dlp at that bundle, and keeps
HTTPS certificate validation enabled. This is required for users whose network
is intentionally mediated by a trusted local proxy; `--no-check-certificates`
is never used.

The release pipeline is responsible for notarizing the final bundle with the
real Developer ID credentials. The bundled toolchain is always retained, so
first use works on restricted networks and a failed compatibility refresh never
removes the last known-good implementation.

## Reviewed site-compatibility refreshes

Video sites change more frequently than the app itself. Release builds can opt
into NDM's separate compatibility feed by setting both:

```bash
NDM_SITE_COMPATIBILITY_MANIFEST_URL=https://updates.example/ndm/site-compatibility.json
NDM_SITE_COMPATIBILITY_PUBLIC_KEY='<base64 Ed25519 public key>'
```

The feed does not invoke yt-dlp's self-updater. NDM first verifies an
Ed25519-signed manifest, then enforces HTTPS, app-version/platform constraints,
declared byte size, SHA-256, and the binary's own reported version. Installation
uses an immutable version directory plus a tiny atomic `current.json` pointer in
Application Support. The signature, hash, executable bit, and reported version
are revalidated before the refreshed binary is selected. Any failure silently
falls back to the notarized app-bundled version.

Release operators create the detached signed envelope with:

```bash
NDM_SITE_COMPATIBILITY_PRIVATE_KEY='<base64 Ed25519 private key>' \
  Scripts/sign-site-compatibility-manifest.swift \
  ./yt-dlp_macos 2026.07.18 1.0.0 \
  https://updates.example/ndm/2026.07.18/yt-dlp_macos \
  ./site-compatibility.json
```

The private key is release infrastructure only and must never be stored in the
repository or application bundle. In the product UI this capability is called
"Site compatibility"; implementation names remain private.

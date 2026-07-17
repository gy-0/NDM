#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="${1:-$ROOT/dist/NDM.app}"
TOOLS="$APP/Contents/Resources/Tools"
REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ndm-bundle-check.XXXXXX")"
trap 'rm -rf "$REPORT_DIR"' EXIT

fail() {
  print -u2 "Bundle verification failed: $1"
  exit 1
}

[[ -x "$APP/Contents/MacOS/NDM" ]] || fail "missing app executable"
[[ -s "$APP/Contents/Resources/MediaToolchain.plist" ]] || fail "missing tool manifest"
[[ -d "$APP/Contents/Resources/Licenses" ]] || fail "missing licenses"

for name in yt-dlp ffmpeg deno; do
  tool="$TOOLS/$name"
  [[ -x "$tool" ]] || fail "missing executable $name"
  codesign --verify --strict "$tool" || fail "$name is not signed"

  # Universal Mach-O files print per-architecture headers; dependency records
  # are the indented rows below them.
  forbidden="$(otool -L "$tool" | awk '/^[[:space:]]+(@|\/)/ {print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|@executable_path/|@loader_path/)' || true)"
  [[ -z "$forbidden" ]] || fail "$name depends on files outside macOS or the app: $forbidden"
done

codesign --verify --deep --strict "$APP" || fail "app signature is invalid"

env -i \
  HOME="$REPORT_DIR/home" \
  TMPDIR="$REPORT_DIR" \
  PATH="/usr/bin:/bin" \
  LC_ALL=C \
  "$APP/Contents/MacOS/NDM" --verify-bundled-tools > "$REPORT_DIR/report.json"

[[ "$(plutil -extract ready raw -o - "$REPORT_DIR/report.json")" == "true" ]] \
  || fail "one or more media tools cannot run"
[[ "$(plutil -extract allBundled raw -o - "$REPORT_DIR/report.json")" == "true" ]] \
  || fail "the app resolved a tool outside its own bundle"

print "Verified zero-setup media toolchain: $APP"

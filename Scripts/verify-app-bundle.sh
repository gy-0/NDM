#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="${1:-$ROOT/dist/NDM.app}"
TOOLS="$APP/Contents/Resources/Tools"
REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ndm-bundle-check.XXXXXX")"
# REPORT_DIR is an exact mktemp-created path. Bypass interactive/Trash wrappers
# so release verification never leaves temporary homes behind.
trap '/bin/rm -rf -- "$REPORT_DIR"' EXIT

fail() {
  print -u2 "Bundle verification failed: $1"
  exit 1
}

minimum_versions() {
  vtool -show-build "$1" | awk '
    $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { block = "legacy"; next }
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { block = "build"; next }
    block == "legacy" && $1 == "version" { print $2; block = ""; next }
    block == "build" && $1 == "minos" { print $2; block = ""; next }
  '
}

version_at_most() {
  awk -v actual="$1" -v declared="$2" 'BEGIN {
    split(actual, a, "."); split(declared, d, ".")
    for (i = 1; i <= 3; i++) {
      av = (a[i] == "" ? 0 : a[i]) + 0
      dv = (d[i] == "" ? 0 : d[i]) + 0
      if (av < dv) exit 0
      if (av > dv) exit 1
    }
    exit 0
  }'
}

[[ -x "$APP/Contents/MacOS/NDM" ]] || fail "missing app executable"
[[ -s "$APP/Contents/Resources/NDM.icns" ]] || fail "missing app icon"
[[ "$(plutil -extract CFBundleIconFile raw -o - "$APP/Contents/Info.plist")" == "NDM.icns" ]] \
  || fail "app icon is not declared in Info.plist"
[[ -s "$APP/Contents/Resources/MediaToolchain.plist" ]] || fail "missing tool manifest"
[[ -d "$APP/Contents/Resources/Licenses" ]] || fail "missing licenses"

declared_minimum="$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist")"
for executable in "$APP/Contents/MacOS/NDM" "$TOOLS/yt-dlp" "$TOOLS/ffmpeg" "$TOOLS/deno"; do
  while IFS= read -r binary_minimum; do
    [[ -z "$binary_minimum" ]] && continue
    version_at_most "$binary_minimum" "$declared_minimum" \
      || fail "$(basename "$executable") requires macOS $binary_minimum but the app declares $declared_minimum"
  done < <(minimum_versions "$executable")
done

[[ -d "$TOOLS/_internal" ]] \
  || fail "yt-dlp is missing its unpackaged runtime (_internal); onefile builds pay ~25s per launch"

for name in yt-dlp ffmpeg deno; do
  tool="$TOOLS/$name"
  [[ -x "$tool" ]] || fail "missing executable $name"
  codesign --verify --strict "$tool" || fail "$name is not signed"

  # Universal Mach-O files print per-architecture headers; dependency records
  # are the indented rows below them.
  forbidden="$(otool -L "$tool" | awk '/^[[:space:]]+(@|\/)/ {print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|@executable_path/|@loader_path/)' || true)"
  [[ -z "$forbidden" ]] || fail "$name depends on files outside macOS or the app: $forbidden"
done

for encoder in h264_videotoolbox aac; do
  "$TOOLS/ffmpeg" -hide_banner -encoders 2>/dev/null \
    | grep -Eq "[[:space:]]${encoder}[[:space:]]" \
    || fail "ffmpeg is missing required encoder: $encoder"
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

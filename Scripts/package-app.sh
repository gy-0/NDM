#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="${NDM_OUTPUT_DIR:-$ROOT/dist}"
APP="$OUT/NDM.app"
TOOLS="$APP/Contents/Resources/Tools"
LICENSES="$APP/Contents/Resources/Licenses"
YTDLP_BIN="${YTDLP_BIN:-$ROOT/Vendor/Tools/yt-dlp}"
FFMPEG_BIN="${FFMPEG_BIN:-$ROOT/Vendor/Tools/ffmpeg}"
DENO_BIN="${DENO_BIN:-$ROOT/Vendor/Tools/deno}"
SOURCE_LICENSES="$ROOT/Vendor/Tools/Licenses"

required_licenses=(
  "$SOURCE_LICENSES/yt-dlp-Unlicense.txt"
  "$SOURCE_LICENSES/yt-dlp-third-party.txt"
  "$SOURCE_LICENSES/ffmpeg-LGPL-2.1.txt"
  "$SOURCE_LICENSES/deno-MIT.txt"
)

for tool in "$YTDLP_BIN" "$FFMPEG_BIN" "$DENO_BIN"; do
  if [[ ! -x "$tool" ]]; then
    print -u2 "Missing executable media tool: $tool"
    print -u2 "Release packaging requires standalone yt-dlp, ffmpeg, and deno binaries."
    exit 1
  fi
done
for notice in "${required_licenses[@]}"; do
  if [[ ! -s "$notice" ]]; then
    print -u2 "Missing third-party notice: $notice"
    print -u2 "Run Scripts/prepare-media-tools.sh before release packaging."
    exit 1
  fi
done

cd "$ROOT"
swift build -c release --disable-sandbox

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$TOOLS" "$LICENSES"
cp "$ROOT/.build/release/NDM" "$APP/Contents/MacOS/NDM"
cp -L "$YTDLP_BIN" "$TOOLS/yt-dlp"
cp -L "$FFMPEG_BIN" "$TOOLS/ffmpeg"
cp -L "$DENO_BIN" "$TOOLS/deno"
cp "$SOURCE_LICENSES"/*.txt "$LICENSES/"
chmod 755 "$APP/Contents/MacOS/NDM" "$TOOLS/yt-dlp" "$TOOLS/ffmpeg" "$TOOLS/deno"

PLIST="$APP/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleName -string NDM "$PLIST"
plutil -insert CFBundleDisplayName -string NDM "$PLIST"
plutil -insert CFBundleExecutable -string NDM "$PLIST"
plutil -insert CFBundleIdentifier -string dev.ndm.open "$PLIST"
plutil -insert CFBundlePackageType -string APPL "$PLIST"
plutil -insert CFBundleShortVersionString -string "${NDM_VERSION:-0.1.0}" "$PLIST"
plutil -insert CFBundleVersion -string "${NDM_BUILD_NUMBER:-1}" "$PLIST"
plutil -insert LSMinimumSystemVersion -string "${NDM_MINIMUM_MACOS:-14.0}" "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"
if [[ -n "${NDM_PURCHASE_URL:-}" ]]; then
  plutil -insert NDMPurchaseURL -string "$NDM_PURCHASE_URL" "$PLIST"
fi

MANIFEST="$APP/Contents/Resources/MediaToolchain.plist"
plutil -create xml1 "$MANIFEST"
for name in yt-dlp ffmpeg deno; do
  tool_path="$TOOLS/$name"
  key="${name//-/_}"
  if [[ "$name" == "ffmpeg" ]]; then
    version="$("$tool_path" -version 2>&1 | head -n 1)"
  else
    version="$("$tool_path" --version 2>&1 | head -n 1)"
  fi
  plutil -insert "$key" -dictionary "$MANIFEST"
  plutil -insert "$key.version" -string "$version" "$MANIFEST"
  plutil -insert "$key.sha256" -string "$(shasum -a 256 "$tool_path" | awk '{print $1}')" "$MANIFEST"
  plutil -insert "$key.architecture" -string "$(file -b "$tool_path")" "$MANIFEST"
done

identity="${CODESIGN_IDENTITY:--}"
sign_one() {
  local target="$1"
  if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$target"
  else
    codesign --force --options runtime --timestamp --sign "$identity" "$target"
  fi
}

sign_one "$TOOLS/yt-dlp"
sign_one "$TOOLS/ffmpeg"
sign_one "$TOOLS/deno"
if [[ "$identity" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$APP"
fi

"$ROOT/Scripts/verify-app-bundle.sh" "$APP"

print "$APP"

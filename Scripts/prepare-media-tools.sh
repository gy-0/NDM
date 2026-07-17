#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DEST="${NDM_TOOL_OUTPUT_DIR:-$ROOT/Vendor/Tools}"
LICENSES="$DEST/Licenses"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ndm-media-tools.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

YTDLP_VERSION="${YTDLP_VERSION:-2026.07.04}"
DENO_VERSION="${DENO_VERSION:-2.9.3}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
FFMPEG_SIGNING_FINGERPRINT="FCF986EA15E6E293A5644F10B4322F04D67658D8"

arch="$(uname -m)"
case "$arch" in
  arm64) deno_arch="aarch64" ;;
  x86_64) deno_arch="x86_64" ;;
  *) print -u2 "Unsupported Mac architecture: $arch"; exit 1 ;;
esac

mkdir -p "$DEST" "$LICENSES"

print "Preparing official yt-dlp $YTDLP_VERSION…"
ytdlp_base="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
curl -fL "$ytdlp_base/yt-dlp_macos" -o "$WORK/yt-dlp"
curl -fL "$ytdlp_base/SHA2-256SUMS" -o "$WORK/yt-dlp-sums"
ytdlp_sha="$(awk '$2 == "yt-dlp_macos" {print $1}' "$WORK/yt-dlp-sums")"
[[ -n "$ytdlp_sha" ]] || { print -u2 "yt-dlp checksum missing"; exit 1; }
[[ "$(shasum -a 256 "$WORK/yt-dlp" | awk '{print $1}')" == "$ytdlp_sha" ]] \
  || { print -u2 "yt-dlp checksum mismatch"; exit 1; }
curl -fL "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/LICENSE" \
  -o "$LICENSES/yt-dlp-Unlicense.txt"
curl -fL "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/THIRD_PARTY_LICENSES.txt" \
  -o "$LICENSES/yt-dlp-third-party.txt"

print "Preparing official Deno $DENO_VERSION…"
deno_asset="deno-${deno_arch}-apple-darwin.zip"
deno_base="https://github.com/denoland/deno/releases/download/v$DENO_VERSION"
curl -fL "$deno_base/$deno_asset" -o "$WORK/deno.zip"
curl -fL "$deno_base/$deno_asset.sha256sum" -o "$WORK/deno.sha256sum"
deno_sha="$(awk '{print $1}' "$WORK/deno.sha256sum")"
[[ "$(shasum -a 256 "$WORK/deno.zip" | awk '{print $1}')" == "$deno_sha" ]] \
  || { print -u2 "Deno checksum mismatch"; exit 1; }
unzip -q -j "$WORK/deno.zip" deno -d "$WORK/deno-unpacked"
curl -fL "https://raw.githubusercontent.com/denoland/deno/v$DENO_VERSION/LICENSE.md" \
  -o "$LICENSES/deno-MIT.txt"

print "Building dependency-free FFmpeg $FFMPEG_VERSION from signed source…"
ffmpeg_base="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
curl -fL "$ffmpeg_base" -o "$WORK/ffmpeg.tar.xz"
curl -fL "$ffmpeg_base.asc" -o "$WORK/ffmpeg.tar.xz.asc"
curl -fL "https://ffmpeg.org/ffmpeg-devel.asc" -o "$WORK/ffmpeg-devel.asc"
mkdir -m 700 "$WORK/gnupg"
GNUPGHOME="$WORK/gnupg" gpg --batch --import "$WORK/ffmpeg-devel.asc" >/dev/null 2>&1
fingerprints="$(GNUPGHOME="$WORK/gnupg" gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10}')"
print "$fingerprints" | grep -qx "$FFMPEG_SIGNING_FINGERPRINT" \
  || { print -u2 "Unexpected FFmpeg signing key"; exit 1; }
GNUPGHOME="$WORK/gnupg" gpg --batch --verify "$WORK/ffmpeg.tar.xz.asc" "$WORK/ffmpeg.tar.xz"
mkdir "$WORK/ffmpeg-source"
tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK/ffmpeg-source" --strip-components=1
(
  cd "$WORK/ffmpeg-source"
  ./configure \
    --prefix="$WORK/ffmpeg-install" \
    --disable-doc \
    --disable-debug \
    --disable-ffplay \
    --disable-ffprobe \
    --disable-shared \
    --enable-static \
    --disable-autodetect \
    --enable-audiotoolbox \
    --enable-videotoolbox \
    --enable-securetransport
  make -j"$(sysctl -n hw.logicalcpu)" ffmpeg
)
cp "$WORK/ffmpeg-source/ffmpeg" "$WORK/ffmpeg"
cp "$WORK/ffmpeg-source/COPYING.LGPLv2.1" "$LICENSES/ffmpeg-LGPL-2.1.txt"

cp "$WORK/yt-dlp" "$DEST/yt-dlp"
cp "$WORK/ffmpeg" "$DEST/ffmpeg"
cp "$WORK/deno-unpacked/deno" "$DEST/deno"
chmod 755 "$DEST/yt-dlp" "$DEST/ffmpeg" "$DEST/deno"

for tool in yt-dlp ffmpeg deno; do
  # Universal Mach-O files include an extra per-architecture header in otool's
  # output. Only indented dependency rows are dylib paths.
  forbidden="$(otool -L "$DEST/$tool" | awk '/^[[:space:]]+\// {print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
  [[ -z "$forbidden" ]] || { print -u2 "$tool is not standalone: $forbidden"; exit 1; }
done

print "Prepared zero-setup media toolchain in $DEST"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: generate_vless_qr.sh VLESS_URL OUTPUT_PNG" >&2
}

[[ $# -eq 2 ]] || { usage; exit 64; }

vless_url=$1
output_png=$2

[[ $vless_url == vless://* ]] || { echo "input is not a VLESS URL" >&2; exit 65; }
command -v qrcode >/dev/null 2>&1 || command -v npx >/dev/null 2>&1 || { echo "qrcode or npx is required to generate the QR code" >&2; exit 69; }

mkdir -p "$(dirname "$output_png")"
cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/provision-3x-ui-npm.XXXXXX")
cleanup() {
  find "$cache_dir" -type f -delete 2>/dev/null || true
  find "$cache_dir" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}
trap cleanup EXIT

if command -v qrcode >/dev/null 2>&1; then
  qrcode \
    --output "$output_png" \
    --error H \
    --width 900 \
    "$vless_url" >/dev/null
else
  npm_config_cache=$cache_dir npx --yes qrcode \
    --output "$output_png" \
    --error H \
    --width 900 \
    "$vless_url" >/dev/null
fi

[[ -s $output_png ]] || { echo "QR generation produced no image" >&2; exit 70; }
chmod 600 "$output_png"
printf '%s\n' "$output_png"

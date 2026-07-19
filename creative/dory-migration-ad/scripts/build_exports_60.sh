#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
raw_render="${1:-$project_dir/renders/dory-migration-ad-4k-60fps-raw.mp4}"
export_dir="$project_dir/exports"

if [[ ! -f "$raw_render" ]]; then
  print -u2 "Missing render: $raw_render"
  exit 1
fi

mkdir -p "$export_dir"

archive="$export_dir/Dory-Bring-the-Work-4K-60fps.mp4"
social="$export_dir/Dory-Bring-the-Work-1080p-60fps.mp4"

cp "$raw_render" "$archive"

ffmpeg -y -hide_banner -nostats \
  -i "$archive" \
  -vf "scale=1920:1080:flags=lanczos" \
  -r 60 -c:v libx264 -preset slow -crf 16 -profile:v high -level 4.2 -pix_fmt yuv420p \
  -c:a aac -b:a 256k -ar 48000 -movflags +faststart \
  "$social"

print "$archive"
print "$social"

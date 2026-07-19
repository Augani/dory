#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
raw_render="${1:-$project_dir/renders/dory-migration-ad-4k-30fps-raw.mp4}"
export_dir="$project_dir/exports"

if [[ ! -f "$raw_render" ]]; then
  print -u2 "Missing render: $raw_render"
  exit 1
fi

mkdir -p "$export_dir"

archive="$export_dir/Dory-Bring-the-Work-4K-30fps.mp4"
social="$export_dir/Dory-Bring-the-Work-1080p-30fps.mp4"
poster="$export_dir/Dory-Bring-the-Work-poster.png"
contact_sheet="$export_dir/Dory-Bring-the-Work-contact-sheet.png"
voice_proof="$export_dir/Dory-Bring-the-Work-voice-proof.m4a"

cp "$raw_render" "$archive"

ffmpeg -y -hide_banner -nostats \
  -i "$archive" \
  -vf "scale=1920:1080:flags=lanczos" \
  -r 30 -c:v libx264 -preset slow -crf 16 -profile:v high -level 4.2 -pix_fmt yuv420p \
  -c:a aac -b:a 256k -ar 48000 -movflags +faststart \
  "$social"

ffmpeg -y -hide_banner -nostats \
  -ss 30.05 -i "$archive" -frames:v 1 -update 1 \
  "$poster"

# One settled hero moment from each scene: hook, carried objects, discovery,
# preflight, verified migration, and the final brand card (30 fps source).
ffmpeg -y -hide_banner -nostats \
  -i "$archive" \
  -vf "select='eq(n\,75)+eq(n\,225)+eq(n\,396)+eq(n\,543)+eq(n\,723)+eq(n\,846)',setpts=N/(30*TB),scale=1200:675:flags=lanczos,tile=3x2:padding=20:margin=20:color=F6F9FE" \
  -frames:v 1 -update 1 \
  "$contact_sheet"

ffmpeg -y -hide_banner -nostats \
  -i "$project_dir/assets/narration-master.wav" \
  -c:a aac -b:a 192k -ar 48000 \
  "$voice_proof"

print "$archive"
print "$social"
print "$poster"
print "$contact_sheet"
print "$voice_proof"

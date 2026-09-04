#!/usr/bin/env bash
# Renders docs/social-preview.gif (1280x640, the GitHub "Social preview" format) from
# docs/demo.gif: the brand ground drawn by social-preview-bg.py (cream, 56 px grid,
# orange glow, Clash Display + Owners), the animated status line below.
# Also writes docs/social-preview.png (last frame) for hosts that want a still.
# Run from the repo root after re-rendering docs/demo.gif with vhs. Needs ffmpeg,
# python3 with Pillow.
set -euo pipefail
BG="$(mktemp -t social-preview-bg).png"
trap 'rm -f "$BG"' EXIT
python3 docs/demo/social-preview-bg.py "$BG"
ffmpeg -v error -y -loop 1 -i "$BG" -i docs/demo.gif -filter_complex "
[1:v]scale=1120:150:flags=lanczos[term];
[0:v][term]overlay=x=80:y=362:shortest=1,split[a][b];
[a]palettegen=max_colors=192:stats_mode=diff[p];
[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" docs/social-preview.gif
LAST="$(( $(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 docs/social-preview.gif) - 1 ))"
ffmpeg -v error -y -i docs/social-preview.gif -vf "select=eq(n\,${LAST})" -vframes 1 docs/social-preview.png
ls -la docs/social-preview.gif docs/social-preview.png

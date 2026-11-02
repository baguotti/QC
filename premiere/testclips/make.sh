#!/bin/zsh
# Renders LineFinder test clips with green lines at known frames (23.976 fps, H.264 4:2:0, textured moving picture):
#   frames  48–95   top edge        1 px      frames 336–383  right edge      3 px
#   frames 144–191  bottom edge     2 px      frames 432–479  split H, row 540 (1080p) / 1080 (4K)
#   frames 240–287  left edge       1 px      frames 528–575  split V, col 960 (1080p) / 1920 (4K)
# Everything else is clean. Seams only show with "Split-screen seams" on. 4K doubles positions and thicknesses.
# Usage: premiere/testclips/make.sh   → premiere/testclips/LineFinder_Test_1080p.mp4, LineFinder_Test_4K.mp4
set -e
cd "$(dirname "$0")"
render() {  # name width height seconds scale
  local s=$5 G=0x00FF00
  local box="drawbox=x=0:y=0:w=iw:h=$((1*s)):color=${G}:t=fill:enable='between(n,48,95)'"
  box+=",drawbox=x=0:y=ih-$((2*s)):w=iw:h=$((2*s)):color=${G}:t=fill:enable='between(n,144,191)'"
  box+=",drawbox=x=0:y=0:w=$((1*s)):h=ih:color=${G}:t=fill:enable='between(n,240,287)'"
  box+=",drawbox=x=iw-$((3*s)):y=0:w=$((3*s)):h=ih:color=${G}:t=fill:enable='between(n,336,383)'"
  box+=",drawbox=x=0:y=$((540*s)):w=iw:h=$((1*s)):color=${G}:t=fill:enable='between(n,432,479)'"
  box+=",drawbox=x=$((960*s)):y=0:w=$((2*s)):h=ih:color=${G}:t=fill:enable='between(n,528,575)'"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "gradients=s=${2}x${3}:r=24000/1001:d=${4}:n=4:c0=0x7a5a48:c1=0x4a6a8a:c2=0xa08060:c3=0x605a70:speed=0.004" \
    -vf "noise=alls=8,$box,format=yuv420p" \
    -c:v libx264 -preset medium -crf 16 -tag:v avc1 -movflags +faststart "$1"
  echo "$1"
}
render LineFinder_Test_1080p.mp4 1920 1080 60 1
render LineFinder_Test_4K.mp4 3840 2160 20 2

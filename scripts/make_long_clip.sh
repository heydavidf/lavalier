#!/bin/zsh
# Cutoff bug: builds a synthetic long dictation with macOS `say` (voice Daniel, en_GB), as 16 kHz
# mono 16-bit WAV. Twelve numbered sections, each about 25 to 30 s with a thinking pause, so the transcript
# shows exactly which parts arrived ("marker one" ... "marker twelve").
# Usage: scripts/make_long_clip.sh OUT.wav [SECTIONS]   (default 12 sections, about 5.5 minutes)
set -e
out=${1:?usage: make_long_clip.sh OUT.wav [SECTIONS]}
sections=${2:-12}
words=(one two three four five six seven eight nine ten eleven twelve)
text=""
for i in $(seq 1 $sections); do
  w=${words[$i]}
  text+="Marker ${w}. This is section ${w} of the long dictation test. I am talking about the plan for the week, "
  text+="which starts with a review of the budget, then a call with the design team about the new onboarding screens, "
  text+="and later a walk through the warehouse figures with Sarah. [[slnc 1200]] "
  text+="After that I want to write up the notes, send them to the group, and book a follow up for Thursday afternoon. "
  text+="The main risk is that the supplier is late again, so we should keep a buffer of two days in the schedule. "
  text+="End of section ${w}. [[slnc 2000]] "
done
tmp=$(mktemp -d)
say -v Daniel -o "$tmp/clip.aiff" "$text"
afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/clip.aiff" "$out"
rm -rf "$tmp"
afinfo "$out" | grep -E 'duration|Data format'

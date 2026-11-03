#!/usr/bin/env bash
# check-shell-blocks.sh: fail if a shell code block in the Markdown docs would break when pasted into a terminal.
# Usage: bash .github/check-shell-blocks.sh   (from anywhere inside the repository)
# File operands are passed to awk as ./path, so a file name containing = is read as a file, not a variable.
# For every fenced block marked sh, bash, shell or zsh in a tracked .md file, including a fence indented by up to
# three spaces inside a list (its body is read without that indentation):
#   1. No comments. Interactive zsh does not treat # as a comment by default, so a pasted comment runs
#      as text (an apostrophe in it opens a quote and the rest of the block never runs). A # inside
#      quotes, or inside a word such as a URL fragment, is fine.
#   2. The block must parse with `bash -n` (and with `zsh -n` when zsh is installed).
# Exit 1 on any failure.
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Run this inside the repository (git is required)."; exit 1; }
cd "$root" || exit 1

fail=0
report() { printf '%s\n' "$1"; fail=1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/shell-blocks.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT

blocks=0
while IFS= read -r -d '' file; do
  # The awk below writes each shell block to its own file and, once the file is complete, prints
  # "path:first-line<TAB>file" for it.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    blocks=$((blocks + 1))
    block="$work/block-$blocks.sh"
    where="${entry%%$'\t'*}"
    # Comment check: a # outside quotes at the start of a word (after a space, tab, ;, |, & or ().
    comments=$(awk -v where="$where" '
      { line = $0; s = 0; d = 0; prev = " "
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (c == "\\" && !s) { i++; prev = "x"; continue }
          if (c == "\047" && !d) s = !s
          else if (c == "\"" && !s) d = !d
          else if (c == "#" && !s && !d && index(" \t;|&(", prev)) {
            split(where, p, ":"); printf "%s:%d: %s\n", p[1], p[2] + NR - 1, line; break
          }
          prev = c
        }
      }' "$block")
    [ -n "$comments" ] && report "Comment in a shell block (move the explanation into the text around the block):
$comments"
    if ! out=$(bash -n "$block" 2>&1); then
      report "$where: shell block does not parse in bash:
$out"
    fi
    if command -v zsh >/dev/null 2>&1 && ! out=$(zsh -f -n "$block" 2>&1); then
      report "$where: shell block does not parse in zsh:
$out"
    fi
  done < <(awk -v file="$file" -v dir="$work" -v start="$blocks" '
    function done_block() { inblock = 0; close(out); printf "%s:%d\t%s\n", file, first, out }
    /^(   |  | )?```/ {
      if (inblock) { done_block(); next }
      indent = index($0, "```") - 1
      lang = substr($0, indent + 4); sub(/[[:space:]].*$/, "", lang)
      if (lang == "sh" || lang == "bash" || lang == "shell" || lang == "zsh") {
        inblock = 1; n++; out = dir "/block-" (start + n) ".sh"; printf "" > out; first = NR + 1
      }
      next
    }
    inblock { line = $0; for (i = 0; i < indent && substr(line, 1, 1) == " "; i++) line = substr(line, 2); print line > out }
    END { if (inblock) done_block() }
  ' "./$file")
done < <(git ls-files -z -- '*.md')

[ "$fail" -eq 0 ] && echo "shell blocks: $blocks block(s) checked, no comments, all parse"
exit "$fail"

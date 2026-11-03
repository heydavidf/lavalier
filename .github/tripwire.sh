#!/usr/bin/env bash
# tripwire.sh: cheap checks for mistakes coding agents make that linters and secret scanners miss.
# Usage: tripwire.sh [BASE_REF]   (from anywhere inside the repository; it checks the whole repository)
#   Always checks tracked files for junk and personal paths.
#   With BASE_REF (e.g. origin/main or a commit), also checks changes since BASE_REF for silenced checks
#   and for new, edited or renamed files that can switch a check off. BASE_REF must exist, or the run fails.
# Exit 1 on any finding, and when git cannot answer (outside a work tree, missing base, failed git command).
# To accept a line deliberately, put "tripwire-allow: <reason>" on it.
# Extra private words to block (names, client names): TRIPWIRE_WORDS="word1|word2"
set -uo pipefail

allow='tripwire-allow:[[:space:]]*[^[:space:]]'   # the marker must be followed by a reason
fail=0
report() { printf '%s\n' "$1"; fail=1; }

# 0. Refuse to report "clean" when git cannot answer, and always check the whole repository.
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
  echo "tripwire: not inside a git work tree; nothing was checked."
  exit 1
fi
cd "$(git rev-parse --show-toplevel)" || exit 1

# 1. Files that should never be tracked.
if ! files=$(git ls-files); then
  echo "tripwire: git ls-files failed; nothing was checked."
  exit 1
fi
junk='(^|/)(\.env(\.[^/]+)?|\.DS_Store|[^/]*\.db(-shm|-wal|-journal)?|.*\.pyc|settings\.local\.json)$|(^|/)(__pycache__|node_modules|\.grok|\.venv|venv|\.build|\.swiftpm|build|[^/]*\.app)/'
tracked_junk=$(printf '%s\n' "$files" | grep -E "$junk" | grep -v -E '(^|/)\.env\.example$' || true)
[ -n "$tracked_junk" ] && report "Tracked files that should be ignored:
$tracked_junk"

# 1b. Lavalier: recordings, run logs and signing material never belong in the repository.
media=$(printf '%s\n' "$files" | grep -E -i '\.(wav|aiff?|m4a|mp3|caf|jsonl|p12|cer|mobileprovision|provisionprofile)$' || true)
[ -n "$media" ] && report "Recordings, run logs or signing files are tracked:
$media"

# 2. Personal paths and private words in tracked text files. git grep exits 1 for "no match"
#    and 2 or more for an error (for example an invalid TRIPWIRE_WORDS pattern).
pattern='/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|C:\\Users\\'
[ -n "${TRIPWIRE_WORDS:-}" ] && pattern="$pattern|${TRIPWIRE_WORDS}"
matches=$(git grep -I -n -E "$pattern" -- . ':!*.lock' ':!package-lock.json' 2>&1)
rc=$?
if [ "$rc" -gt 1 ]; then
  report "git grep failed, so personal paths were not checked:
$matches"
else
  personal=$(printf '%s\n' "$matches" | grep -v -E "$allow" | grep -v -E '^\.github/tripwire\.sh:' || true)
  [ "$rc" -eq 0 ] && [ -n "$personal" ] && report "Personal paths or private words in tracked files:
$personal"
fi

# 3. Checks silenced since BASE_REF.
if [ $# -ge 1 ]; then
  base="$1"
  if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    report "Base '$base' is not a commit in this repository (fetch it, or pass the commit your change started from)."
  elif ! diff=$(git diff -U0 "$base"...HEAD -- . ':!.github/tripwire.sh' 2>&1); then
    report "git diff against '$base' failed:
$diff"
  else
    silenced='XCTSkip|swiftlint:disable|\.disabled\(|withKnownIssue|# *noqa|# *type: *ignore|eslint-disable|@ts-ignore|@ts-expect-error|@ts-nocheck|biome-ignore|\bas any\b|pytest\.mark\.skip|pytest\.skip\(|unittest\.skip|\b(it|test|describe)\.(skip|todo)\(|\bt\.(skip|todo)\(|\b(skip|todo): *true|\bx(it|describe)\(|--no-verify|gitleaks:allow|continue-on-error: *true|shellcheck +disable|fail: *false'
    added=$(printf '%s\n' "$diff" | grep -E '^\+[^+]' | grep -E "$silenced" | grep -v -E "$allow" || true)
    [ -n "$added" ] && report "New lines that silence a check (add 'tripwire-allow: <reason>' or remove):
$added"
    # New, edited or renamed files whose purpose is to switch a check off (or, for .gitattributes,
    # to hide changes from the diff above) must say why, in a comment containing 'tripwire-allow: <reason>'.
    if ! names=$(git diff --name-only --diff-filter=AMR "$base"...HEAD 2>&1); then
      report "git diff --name-only against '$base' failed:
$names"
      names=""
    fi
    configs=$(printf '%s\n' "$names" | grep -E '(^|/)(\.gitleaksignore|\.gitleaks\.toml|\.lycheeignore|lychee\.toml|\.shellcheckrc|\.gitattributes)$' || true)
    unexplained=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -q -E "$allow" "$f" 2>/dev/null || unexplained="${unexplained:+$unexplained
}$f"
    done < <(printf '%s\n' "$configs")
    [ -n "$unexplained" ] && report "New or edited files that can switch a check off, without a 'tripwire-allow: <reason>' comment:
$unexplained"
  fi
fi

[ "$fail" -eq 0 ] && echo "tripwire: clean"
exit "$fail"

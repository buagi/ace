#!/usr/bin/env bash
# supply-chain.sh — mechanical CI guard against unpinned / unverified network installs.
#
# Scans `ace` + `lib/*.sh` (EXECUTED code only — shell comments are stripped first, so a hardening
# note that merely mentions a bad pattern doesn't self-trip) and FAILS (nonzero) on:
#   (a) UNPINNED version resolution in a download context — `releases/latest` or `go.dev/VERSION`
#       (the floating-version anti-pattern this guard exists to stop).
#   (b) a `curl … | sh` / `curl … | bash` remote-script install that is NOT in the allowlist
#       (tests/supply-chain-allowlist.txt).
#   (c) a release-artifact fetch (`releases/download/` or `go.dev/dl/`) with NO integrity check on the
#       SAME line — neither `sha256sum -c` (inline, mergiraf-style) nor `fetch_verified` (the shared
#       verify-before-install helper). A download that isn't hash-checked is the whole problem.
#
# It also asserts fetch_verified still actually verifies (contains `sha256sum -c`), so rule (c) can't be
# satisfied by a gutted helper.
#
# The FIX for a failure is always the same: pin the version and verify a sha256 — copy the mergiraf
# block or route the download through fetch_verified (see the jq/gh/upx/go blocks in lib/install.sh).
#
# PERF: comments are stripped once per file (one sed), then each rule is a single grep pass whose few
# hits are checked with pure-bash predicates. An earlier version shelled out ~6 processes PER LINE
# (~9.4k lines), which took ~40s — slow enough that a CI guard gets disabled. Keep it subprocess-light.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOWLIST="$ROOT/tests/supply-chain-allowlist.txt"
fail=0

# Files to scan: the CLI entrypoint + every library. (Not tests/ — this file and the allowlist
# necessarily contain the very patterns we hunt for, as strings.)
FILES=("$ROOT/ace")
for f in "$ROOT"/lib/*.sh; do [ -f "$f" ] && FILES+=("$f"); done

# --- load the curl|bash allowlist (first field = url substring; rest = human reason) ---
ALLOW=()
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    ALLOW+=("${line%%[[:space:]]*}")
  done < "$ALLOWLIST"
else
  echo "✗ supply-chain: allowlist missing: $ALLOWLIST"; exit 1
fi

report() { echo "✗ supply-chain: $1"; fail=1; }

is_allowlisted() {  # <code-line> -> 0 if any allowlist url-substring occurs in it
  local l="$1" sub
  for sub in "${ALLOW[@]}"; do [ -n "$sub" ] && case "$l" in *"$sub"*) return 0 ;; esac; done
  return 1
}

# A '#' at line-start or after whitespace begins a comment; a '#' inside ${#arr} or a URL fragment
# (preceded by a non-space) is preserved. Done once per file, not once per line.
STRIP_RE='s/(^|[[:space:]])#.*$/\1/'

# pipe-into-a-shell: `| sh`, `| bash`, tolerating a trailing quote/paren (…| bash') but not `| shellcheck`
PIPE_SH_RE='[|][[:space:]]*(ba)?sh([^[:alnum:]_]|$)'

# Stripped output goes to a temp file, never through a shell variable: command substitution drops NUL
# bytes and prints a `ignored null byte in input` warning for some inputs (seen on lib/merge-structured.sh).
STRIPPED="$(mktemp)"; trap 'rm -f "$STRIPPED"' EXIT

for file in "${FILES[@]}"; do
  rel="${file#"$ROOT"/}"
  sed -E "$STRIP_RE" "$file" > "$STRIPPED" 2>/dev/null

  # (a) unpinned/floating version resolution in a download context
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    report "$rel:${hit%%:*} — UNPINNED version resolution ('releases/latest' or 'go.dev/VERSION'). Pin an exact version and verify a sha256 (see the mergiraf/jq/gh/upx/go blocks in lib/install.sh)."
  done < <(grep -nE 'releases/latest|go\.dev/VERSION' "$STRIPPED" || true)

  # (b) curl|wget piped into a shell, not on the allowlist
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    code="${hit#*:}"
    [[ $code =~ $PIPE_SH_RE ]] || continue
    is_allowlisted "$code" && continue
    report "$rel:${hit%%:*} — un-allowlisted 'curl … | sh|bash' remote-script install. Either pin+verify a release binary (fetch_verified), or add the URL to tests/supply-chain-allowlist.txt with a reason + follow-up."
  done < <(grep -nE 'curl|wget' "$STRIPPED" || true)

  # (c) release-artifact fetch with no integrity check on the same line
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    code="${hit#*:}"
    [[ $code =~ (sha256sum[[:space:]]+-c|fetch_verified) ]] && continue
    report "$rel:${hit%%:*} — release-artifact download with NO sha256 verification on the line. Route it through fetch_verified, or add an inline 'sha256sum -c' (see the mergiraf block in lib/install.sh)."
  done < <(grep -nE 'releases/download/|go\.dev/dl/' "$STRIPPED" || true)
done

# --- integrity of the verifier itself: fetch_verified must actually check a sha256 ---
if ! grep -Eq '^fetch_verified\(\)' "$ROOT/lib/install.sh"; then
  report "lib/install.sh — fetch_verified() is missing; rule (c) relies on it as the verify marker."
elif ! grep -q 'sha256sum -c' "$ROOT/lib/install.sh"; then
  report "lib/install.sh — no 'sha256sum -c' present; fetch_verified must fail-closed on a hash mismatch."
fi

if [ "$fail" = 0 ]; then
  echo "✓ supply-chain: no unpinned/unverified installs; ${#ALLOW[@]} allowlisted vendor script(s); fetch_verified verifies."
  exit 0
else
  echo "✗ supply-chain: violations above — pin the version and verify a sha256 (copy the mergiraf block, or use fetch_verified)."
  exit 1
fi

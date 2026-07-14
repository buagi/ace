#!/usr/bin/env bash
# Tiered: ./ci.sh = fast host gate; ./ci.sh --container = full VPS parity.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
MODE="fast"; { [ "${1:-}" = "--container" ] || [ "${CONTAINER:-}" = "1" ]; } && MODE="container"
[ "$MODE" = container ] && [ ! -f Containerfile ] && { echo "[ci] no Containerfile — running the host gate."; MODE="fast"; }
export CGO_ENABLED=0 CI=1
fail=0; section(){ printf '\n== %s ==\n' "$1"; }
section "[1/7] Build + test ($MODE)"
if [ "$MODE" = container ]; then
  if podman build --force-rm --target test -t localhost/ci:dev -f Containerfile .; then _rc=0; else _rc=1; fi
  podman image prune -f >/dev/null 2>&1 || true   # reclaim this build's dangling layers
  [ "$_rc" = 0 ] || { echo RED; exit 1; }
else
  go build ./... || fail=1
  go vet ./... || fail=1
  # -race needs cgo, but builds are CGO_ENABLED=0 (fully static) — so enable cgo for the race test ONLY
  # when a C compiler is present (else 'go test -race' errors "requires cgo"); otherwise plain tests.
  # -timeout 120s: a deadlocked/flaky concurrency test surfaces as RED in 2min, not the 10-min default
  # (a scheduler-dependent hang once merged silently and poisoned every downstream branch). GO_TEST_COUNT>1
  # (set by the --container merge gate) re-runs to expose that flakiness before it can merge.
  _gtc="${GO_TEST_COUNT:-1}"
  if command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1; then CGO_ENABLED=1 go test ./... -race -timeout 120s -count="$_gtc" -coverprofile=coverage.out -covermode=atomic || fail=1
  else go test ./... -timeout 120s -count="$_gtc" -coverprofile=coverage.out || fail=1; fi
  # coverage is a SIGNAL, not a gate (no blanket % target — that just invites gaming): print the total.
  [ -f coverage.out ] && go tool cover -func=coverage.out 2>/dev/null | tail -1
fi
section "[2/7] Format — gofmt"
unf=$(gofmt -l $(find . -name '*.go' -not -path './brownfield/*' -not -path './.serena/*') 2>/dev/null)
[ -n "$unf" ] && { echo "RED: gofmt — run 'gofmt -w .':"; echo "$unf"; fail=1; }
section "[3/7] staticcheck (if installed)"
if command -v staticcheck >/dev/null 2>&1; then staticcheck ./... || fail=1; else echo "(staticcheck not on PATH — 'ace install' adds it; skipping)"; fi
section "[4/7] Env integrity — os.Getenv vars declared in .env.example"
declared=$(grep -oP '^[A-Z0-9_]+(?==)' .env.example 2>/dev/null | sort -u)
used=$(grep -rhoP 'os\.Getenv\("\K[A-Z0-9_]+' --include='*.go' . 2>/dev/null | sort -u)
miss=$(comm -23 <(printf '%s\n' "$used"|sed '/^$/d') <(printf '%s\n' "$declared"|sed '/^$/d'))
[ -n "$miss" ] && { echo "RED: undeclared env vars (add to .env.example):"; echo "$miss"; fail=1; }
section "[5/7] No stubs / placeholders (depth gate)"
stub=$(grep -rInE '(TODO|FIXME|XXX)|not[ _]implemented|panic\("?TODO' --include='*.go' cmd internal pkg 2>/dev/null | grep -vE '/(brownfield|\.serena)/' | head -20)
[ -n "$stub" ] && { echo "RED: unfinished stubs/markers — complete them (or move notes to .opencode/specs/):"; echo "$stub"; fail=1; }
section "[6/7] Client-bundle secret scan (leaked provider/service keys)"
# Scan the BUILT client bundle only (dist/build/.next/public) for shipped provider/service keys — never
# source, never server-only .env. Add literal substrings to .ci-secretignore to suppress false positives.
csec_dirs=""; for d in dist build .next public; do [ -d "$d" ] && csec_dirs="$csec_dirs $d"; done
if [ -n "$csec_dirs" ]; then
  csec_re='sk_live_|sk_test_|service_role|SUPABASE_SERVICE_ROLE|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9]{36}'
  csec_hits=$(grep -rInE "$csec_re" $csec_dirs 2>/dev/null || true)
  if [ -n "$csec_hits" ] && [ -s .ci-secretignore ]; then csec_hits=$(printf '%s\n' "$csec_hits" | grep -vFf <(grep -v '^$' .ci-secretignore) || true); fi
  if [ -n "$csec_hits" ]; then echo "RED [blocker]: secret/credential shipped in client bundle — move it to server-only env:"; printf '%s\n' "$csec_hits" | head -20; fail=1; else echo "(client bundle clean)"; fi
else echo "(no client bundle dir — skipping)"; fi
section "[7/7] Row-Level Security — RLS enabled per table (Postgres/Supabase)"
# Stack-conditional: runs only when SQL migrations declare CREATE TABLE; clean no-op otherwise.
if grep -rIqE 'CREATE TABLE' --include='*.sql' . 2>/dev/null; then
  rls_tables=$(grep -rhoIE 'CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?[A-Za-z0-9_]+' --include='*.sql' . 2>/dev/null | sed -E 's/.*CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?//; s/".*//' | sort -u)
  for t in $rls_tables; do
    if ! grep -rIqE "ALTER TABLE +(public\.)?\"?${t}\"? +ENABLE ROW LEVEL SECURITY" --include='*.sql' . 2>/dev/null; then
      echo "RED [blocker]: table '${t}' created without ENABLE ROW LEVEL SECURITY"; fail=1
    elif ! grep -rIqE "CREATE POLICY .*ON +(public\.)?\"?${t}\"?" --include='*.sql' . 2>/dev/null; then
      echo "WARN [major]: table '${t}' has RLS enabled but no CREATE POLICY (deny-all — usually unintended)"
    fi
  done
else echo "(no SQL CREATE TABLE — skipping RLS check)"; fi
[ "$fail" = 0 ] && { echo -e "\nCI GREEN ($MODE)"; exit 0; } || { echo -e "\nCI RED ($MODE)"; exit 1; }

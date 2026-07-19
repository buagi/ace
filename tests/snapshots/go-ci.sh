#!/usr/bin/env bash
# Tiered: ./ci.sh = fast host gate; ./ci.sh --container = full VPS parity.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
MODE="fast"; { [ "${1:-}" = "--container" ] || [ "${CONTAINER:-}" = "1" ]; } && MODE="container"
[ "${1:-}" = "--launch" ] && MODE="launch"   # pre-promotion launch-readiness gate (see the launch_readiness_reviewer agent)
[ "$MODE" = container ] && [ ! -f Containerfile ] && { echo "[ci] no Containerfile — running the host gate."; MODE="fast"; }
export CGO_ENABLED=0 CI=1
fail=0; section(){ printf '\n== %s ==\n' "$1"; }
# ── ONE exclusion list for EVERY recursive scan in this gate ────────────────────────────────────────
# Trees this project does not own: dependency installs (node_modules/, .venv/, vendor/), build output,
# and brownfield/ — code adopted by `ace import`, which PROMISES it is "excluded from the gate". It was
# not: the RLS, migration-safety and log-hygiene sections below scanned it anyway, emitted RED [blocker]
# and set fail=1, and .githooks/pre-commit then blocked EVERY commit over somebody else's legacy code.
# Add paths HERE, never inline, so the next section added to this file cannot forget one.
EXCL='/(node_modules|dist|build|\.next|out|vendor|\.git|\.serena|\.venv|venv|brownfield)/'
# grep -r has no regex-based --exclude-dir, so these two wrappers apply $EXCL to a recursive grep:
#   xgrep_l -> the matching FILE list minus excluded paths   ·   xgrep_q -> quiet test (true iff a match)
# Both force -l so the pipe filters PATHS, and both are judged on their TEXT, never on $?: grep returns 1
# for "no match" and xargs returns 123 if any batch did, neither of which means the check failed.
xgrep_l(){ grep -rIl "$@" 2>/dev/null | grep -vE "$EXCL"; }
xgrep_q(){ xgrep_l "$@" | grep -q .; }
# STRICT security gate: an unattended PUBLIC self-merge has no human to catch a "major" security gap, so the
# security [major] warnings below become HARD BLOCKERS (the orchestrator's AUTO-ACCEPT SAFETY RAIL, made
# mechanical). ON when the profile audience is public/customer/enterprise AND auto_merge is on; force either
# way with ACE_STRICT_SECURITY=1 / =0. (Heuristic greps → a false positive blocks a merge; that is the
# fail-closed trade for shipping to real users with no reviewer. Set ACE_STRICT_SECURITY=0 to opt a run out.)
_strict=0
_paud="$(sed -n 's/^[[:space:]]*audience:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
_pam="$(sed -n 's/^[[:space:]]*auto_merge:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
case "$_paud" in oss-public|end-customer|enterprise) case "$_pam" in true|yes|1) _strict=1 ;; esac ;; esac
case "${ACE_STRICT_SECURITY:-}" in 1) _strict=1 ;; 0) _strict=0 ;; esac
_secwarn(){ if [ "$_strict" = 1 ]; then echo "RED [blocker]: $* [strict: public + auto_merge, no human reviewer]"; fail=1; else echo "WARN [major]: $*"; fi; }
if [ "$MODE" = launch ]; then
  section "Launch-readiness (mechanical pre-promotion gate — the launch_readiness_reviewer agent does the judgment)"
  # Composition-aware (like the stack-conditional gates above): only require the DB restore-drill when the
  # project HAS a database, and rollback/SLO/runbook only for a deployed service (deploy_kind=service). A
  # no-DB CLI / library is not NO-GO'd for a backup it cannot have.
  _hasdb=0
  { [ -f package.json ] && grep -qiE '"(pg|postgres|prisma|@prisma/client|drizzle-orm|mysql2?|mongoose|mongodb|better-sqlite3|sqlite3|sequelize|typeorm|knex|kysely|pg-promise|@libsql/client|@neondatabase/serverless|@planetscale/database|@vercel/postgres)"' package.json; } && _hasdb=1
  { [ -f go.mod ] && grep -qiE 'lib/pq|jackc/pgx|jackc/pgconn|go-sql-driver|mattn/go-sqlite3|modernc\.org/sqlite|glebarez/sqlite|gorm\.io|entgo\.io/ent|uptrace/bun|jmoiron/sqlx|mongo-driver' go.mod; } && _hasdb=1
  grep -qiE 'psycopg|sqlalchemy|sqlmodel|asyncpg|pymysql|mysqlclient|mariadb|aiosqlite|pymongo|django|tortoise|peewee|alembic' requirements*.txt pyproject.toml 2>/dev/null && _hasdb=1
  { ls prisma/schema.prisma migrations/*.sql db/migrations/*.sql migrations/0*.py */migrations/0*.py alembic/versions/*.py 2>/dev/null | grep -q .; } && _hasdb=1
  _svc=0; [ "$(sed -n 's/^[[:space:]]*deploy_kind:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)" = service ] && _svc=1
  if [ "$_hasdb" = 1 ]; then
    if [ -f ops/restore-drill.result ] && grep -qiE 'rows_verified=[1-9]|status=(verified|pass|ok)' ops/restore-drill.result 2>/dev/null; then echo "tested restore: recorded"; else echo "NO-GO [blocker]: ops/restore-drill.result missing or shows no verified restore (needs rows_verified / RPO / RTO) — a backup is not done until a restore has been run: ./ops/restore-drill.sh"; fail=1; fi
  else echo "no database detected — restore-drill not required"; fi
  if [ "$_svc" = 1 ]; then
    [ -f ops/rollback.md ] && echo "present: ops/rollback.md" || { echo "NO-GO [blocker]: ops/rollback.md missing — document the tested revert for the last deploy"; fail=1; }
    for a in ops/runbook.md ops/slo.md LAUNCH-READINESS.md; do [ -f "$a" ] && echo "present: $a" || echo "WARN [major]: missing $a (scaffold it; track to verified in LAUNCH-READINESS.md)"; done
  else echo "deploy_kind != service (artifact/library/none) — rollback/SLO/runbook not required"; fi
  [ "$fail" = 0 ] && { echo -e "\nLAUNCH GREEN (mechanical checks pass — now run the launch_readiness_reviewer agent for the full GO/NO-GO)"; exit 0; } || { echo -e "\nLAUNCH RED — NO-GO (fix the [blocker] artifacts above)"; exit 1; }
fi
# The OWNED Go package list — `./...` would build/vet/test/staticcheck brownfield/ too, but `ace import`
# PROMISES imported code is excluded from the gate, and a legacy tree that does not compile made EVERY
# commit RED. Resolved once here and reused by sections [1] and [3]. Unquoted on use is deliberate and
# safe: a Go import path cannot contain whitespace. ($EXCL is for grep -r; go needs package paths.)
# `go list` FAILING and `go list` returning NOTHING are different facts and must be judged separately.
# This line used to be `go list ./... 2>/dev/null | …`: the rc was thrown away with the diagnostics, so a
# module that did not even parse (bad go.mod, unavailable toolchain, broken `replace`, run outside the
# module) produced an EMPTY list, took the "no packages — skipping" branch, and the gate printed CI GREEN
# on a tree that cannot compile. Keep the rc AND the stderr; an empty list is only believed when rc=0.
_golist_rc=0; : > /tmp/ci-golist.err
_golist_out=$(go list ./... 2>/tmp/ci-golist.err) || _golist_rc=$?
_gopkgs=$(printf '%s\n' "$_golist_out" | grep -v '/brownfield' || true)
section "[1/13] Build + test ($MODE)"
if [ "$_golist_rc" != 0 ]; then
  # Deliberately RED in container MODE too: the package list is unusable either way, and a module that
  # does not resolve is a real failure — not something to hand to the build and hope it notices.
  echo "RED: 'go list ./...' failed (rc=$_golist_rc) — the module does not resolve, so build/vet/test cannot be judged:"
  cat /tmp/ci-golist.err
  fail=1
elif [ "$MODE" = container ]; then
  if podman build --force-rm --target test -t localhost/ci:dev -f Containerfile .; then _rc=0; else _rc=1; fi
  podman image prune -f >/dev/null 2>&1 || true   # reclaim this build's dangling layers
  [ "$_rc" = 0 ] || { echo RED; exit 1; }
elif [ -z "$_gopkgs" ]; then
  echo "(no Go packages outside brownfield/ — skipping build/vet/test)"
else
  go build $_gopkgs || fail=1
  go vet $_gopkgs || fail=1
  # -race needs cgo, but builds are CGO_ENABLED=0 (fully static) — so enable cgo for the race test ONLY
  # when a C compiler is present (else 'go test -race' errors "requires cgo"); otherwise plain tests.
  # -timeout 120s: a deadlocked/flaky concurrency test surfaces as RED in 2min, not the 10-min default
  # (a scheduler-dependent hang once merged silently and poisoned every downstream branch). GO_TEST_COUNT>1
  # (set by the --container merge gate) re-runs to expose that flakiness before it can merge.
  _gtc="${GO_TEST_COUNT:-1}"
  if command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1; then CGO_ENABLED=1 go test $_gopkgs -race -timeout 120s -count="$_gtc" -coverprofile=coverage.out -covermode=atomic || fail=1
  else go test $_gopkgs -timeout 120s -count="$_gtc" -coverprofile=coverage.out || fail=1; fi
  # coverage is a SIGNAL, not a gate (no blanket % target — that just invites gaming): print the total.
  [ -f coverage.out ] && go tool cover -func=coverage.out 2>/dev/null | tail -1
fi
section "[2/13] Format — gofmt"
# -print0 | xargs -0: an unquoted $(find …) word-split spaced paths into bogus names. And gofmt's STDERR
# is KEPT: it was 2>/dev/null'd, so a gofmt that could not parse a file printed nothing to stdout and the
# section read "clean" — a real failure reported as a pass. gofmt -l exits 0 for merely-unformatted files,
# so a non-zero rc (or any stderr) means gofmt itself failed and must be RED.
: > /tmp/ci-gofmt.log
unf=$(find . -name '*.go' -type f -print0 2>/dev/null | grep -zvE "$EXCL" | xargs -0 -r gofmt -l 2>/tmp/ci-gofmt.log)
[ -n "$unf" ] && { echo "RED: gofmt — run 'gofmt -w .':"; echo "$unf"; fail=1; }
[ -s /tmp/ci-gofmt.log ] && { echo "RED: gofmt FAILED TO RUN (this used to be silent and read as clean):"; cat /tmp/ci-gofmt.log; fail=1; }
section "[3/13] staticcheck (if installed)"
if ! command -v staticcheck >/dev/null 2>&1; then echo "(staticcheck not on PATH — 'ace install' adds it; skipping)"
elif [ "$_golist_rc" != 0 ]; then echo "(skipped — 'go list ./...' failed; already RED in [1/13])"   # skip, but the run is NOT green
elif [ -z "$_gopkgs" ]; then echo "(no Go packages outside brownfield/ — skipping staticcheck)"
else staticcheck $_gopkgs || fail=1; fi
section "[4/13] Env integrity — os.Getenv vars declared in .env.example"
declared=$(grep -oP '^[A-Z0-9_]+(?==)' .env.example 2>/dev/null | sort -u)
used=$(find . -name '*.go' -type f -print0 2>/dev/null | grep -zvE "$EXCL" | xargs -0 -r grep -hoP 'os\.Getenv\("\K[A-Z0-9_]+' 2>/dev/null | sort -u)
miss=$(comm -23 <(printf '%s\n' "$used"|sed '/^$/d') <(printf '%s\n' "$declared"|sed '/^$/d'))
[ -n "$miss" ] && { echo "RED: undeclared env vars (add to .env.example):"; echo "$miss"; fail=1; }
section "[5/13] No stubs / placeholders (depth gate)"
stub=$(grep -rInE '(TODO|FIXME|XXX)|not[ _]implemented|panic\("?TODO' --include='*.go' cmd internal pkg 2>/dev/null | grep -vE "$EXCL" | head -20)
[ -n "$stub" ] && { echo "RED: unfinished stubs/markers — complete them (or move notes to .opencode/specs/):"; echo "$stub"; fail=1; }
section "[6/13] Client-bundle secret scan (leaked provider/service keys)"
# Scan the BUILT client bundle only (dist/build/.next/public) for shipped provider/service keys — never
# source, never server-only .env. Add literal substrings to .ci-secretignore to suppress false positives.
csec_dirs=""; for d in dist build .next public; do [ -d "$d" ] && csec_dirs="$csec_dirs $d"; done
if [ -n "$csec_dirs" ]; then
  csec_re='sk_live_|sk_test_|service_role|SUPABASE_SERVICE_ROLE|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{20,}|OPENAI_API_KEY|ANTHROPIC_API_KEY'
  csec_hits=$(grep -rInE "$csec_re" $csec_dirs 2>/dev/null || true)
  if [ -n "$csec_hits" ] && [ -s .ci-secretignore ]; then csec_hits=$(printf '%s\n' "$csec_hits" | grep -vFf <(grep -v '^$' .ci-secretignore) || true); fi
  if [ -n "$csec_hits" ]; then echo "RED [blocker]: secret/credential shipped in client bundle — move it to server-only env:"; printf '%s\n' "$csec_hits" | head -20; fail=1; else echo "(client bundle clean)"; fi
else echo "(no client bundle dir — skipping)"; fi
section "[7/13] Row-Level Security — RLS enabled per table (Postgres/Supabase)"
# Stack-conditional: runs only when SQL migrations declare CREATE TABLE; clean no-op otherwise.
# Resolve the OWNED .sql set once through $EXCL — a brownfield/ or vendored migration is not ours to
# police, and it used to RED-block every commit here. Every lookup below reuses this one list, and it is
# ALL owned .sql (not just the CREATE TABLE files) because RLS is usually enabled in a LATER migration.
sql_all=$(find . -name '*.sql' -type f 2>/dev/null | grep -vE "$EXCL" || true)
_sqlgrep(){ printf '%s\n' "$sql_all" | tr '\n' '\0' | xargs -0 -r grep "$@" 2>/dev/null; }   # judge the OUTPUT, never xargs' rc
if [ -n "$sql_all" ] && _sqlgrep -lIE 'CREATE TABLE' | grep -q .; then
  rls_tables=$(_sqlgrep -hoIE 'CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?[A-Za-z0-9_]+' | sed -E 's/.*CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?//; s/".*//' | sort -u)
  for t in $rls_tables; do
    if ! _sqlgrep -lIE "ALTER TABLE +(public\.)?\"?${t}\"? +ENABLE ROW LEVEL SECURITY" | grep -q .; then
      echo "RED [blocker]: table '${t}' created without ENABLE ROW LEVEL SECURITY"; fail=1
    elif ! _sqlgrep -lIE "CREATE POLICY .*ON +(public\.)?\"?${t}\"?" | grep -q .; then
      _secwarn "table '${t}' has RLS enabled but no CREATE POLICY (deny-all — usually unintended)"
    fi
  done
else echo "(no SQL CREATE TABLE — skipping RLS check)"; fi
section "[8/13] LLM call-site guards (cost / abuse)"
# Stack-conditional: runs only when an LLM SDK is a dependency; heuristic [major] warnings, never a hard fail.
if grep -rIqE 'openai|anthropic|langchain|@ai-sdk|llamaindex|@google/generative-ai' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null; then
  llm_calls=$(grep -rIlE '\.chat\.completions\.create|\.messages\.create|\.completions\.create|\.responses\.create|generateText|streamText|generateObject|\.GenerateContent|CreateChatCompletion|CreateMessage|CreateCompletion' --include='*.go' --include='*.ts' --include='*.js' . 2>/dev/null | grep -vE "$EXCL" | head -50 || true)
  if [ -n "$llm_calls" ]; then
    printf '%s\n' "$llm_calls" | xargs grep -lIE 'max_tokens|maxOutputTokens|max_output_tokens|maxTokens|MaxTokens' 2>/dev/null | grep -q . || _secwarn "LLM call site(s) with no visible token cap (max_tokens/maxOutputTokens) — uncapped output is a cost + DoS risk"
    xgrep_q -iE 'budget|rate.?limit|max.?iteration|max.?step|max.?turn' --include='*.go' --include='*.ts' --include='*.js' . || _secwarn "no visible per-user/session budget, rate-limit, or agent max-iteration cap near LLM calls"
  else echo "(LLM SDK present but no direct call site found — skipping)"; fi
else echo "(no LLM SDK dependency — skipping)"; fi
section "[9/13] Webhook handler integrity (payment/event webhooks)"
# Stack-conditional: runs only when a MONEY webhook handler is present; clean no-op otherwise.
wh_files=$( { grep -rIliE 'webhook|constructEvent|Stripe-Signature|whsec_' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f -iname '*webhook*' 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -50 )
money_wh=""; [ -n "$wh_files" ] && money_wh=$(printf '%s\n' "$wh_files" | xargs grep -lIiE 'stripe|paypal|braintree|paddle|lemonsqueez|razorpay|payment|charge|subscription|checkout|billing' 2>/dev/null || true)
if [ -n "$money_wh" ]; then
  wh_sig='constructEvent|verifyHeader|verifySignature|Stripe-Signature|X-Hub-Signature|createHmac|compare_digest|hmac\.new|ConstructEvent|ValidateSignature|WebhookSignature'
  if printf '%s\n' "$money_wh" | xargs grep -lIE "$wh_sig" 2>/dev/null | grep -q .; then
    echo "(webhook signature verification present)"
    wh_dedupe='event[._]?id|eventId|idempotenc|processed|dedup|on conflict|already|\bseen\b'
    printf '%s\n' "$money_wh" | xargs grep -lIiE "$wh_dedupe" 2>/dev/null | grep -q . || _secwarn "money webhook has no visible event-ID dedupe (at-least-once delivery + multi-day retries can double-process)"
  else
    echo "RED [blocker]: money webhook handler with NO signature verification — forgeable 'payment succeeded':"; printf '%s\n' "$money_wh" | head -10; fail=1
  fi
else echo "(no payment webhook handler — skipping)"; fi
section "[10/13] Auth & session edge cases (reset tokens / enumeration)"
# Stack-conditional: runs only when auth routes are present; heuristic [major] warnings, never a hard fail.
auth_files=$( { grep -rIliE 'password|reset[_-]?token|forgot|sign[_-]?in|next-auth|passport|lucia|bcrypt|argon2' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f \( -iname '*auth*' -o -iname '*login*' -o -iname '*password*' \) 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -80 )
if [ -n "$auth_files" ]; then
  if printf '%s\n' "$auth_files" | xargs grep -lIiE 'no such (user|account)|(email|user|account) not found|does ?n.?t exist|no account (with|found)' 2>/dev/null | grep -q .; then
    _secwarn "an auth response reveals whether an account exists (enumeration) — return a GENERIC message for existing AND non-existing accounts"
  fi
  reset_files=$(printf '%s\n' "$auth_files" | xargs grep -lIiE 'reset[_-]?token|password[_-]?reset|forgot' 2>/dev/null || true)
  if [ -n "$reset_files" ]; then
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'hash|bcrypt|argon2|scrypt|sha256|createhash|digest' 2>/dev/null | grep -q . || _secwarn "reset token may be stored in plaintext — store only its HASH and compare hashes"
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'expir|ttl|valid[_-]?until|used|consumed|redeemed|single[_-]?use' 2>/dev/null | grep -q . || _secwarn "reset token has no visible expiry or single-use flag — make it time-limited AND single-use"
  fi
else echo "(no auth routes — skipping)"; fi
section "[11/13] Migration safety (expand-contract)"
# Stack-conditional: runs only when SQL migration files are present; clean no-op otherwise.
mig_files=$(grep -rIlE 'ALTER TABLE|DROP TABLE|DROP COLUMN|CREATE TABLE|RENAME' --include='*.sql' . 2>/dev/null | grep -vE "$EXCL" | head -80 || true)
if [ -n "$mig_files" ]; then
  while IFS= read -r mf; do [ -n "$mf" ] || continue
    if grep -IiqE 'DROP (TABLE|COLUMN)|RENAME (TO|COLUMN)|ALTER COLUMN[^;]*DROP' "$mf" 2>/dev/null; then
      grep -IiqE -e '--[[:space:]]*down\b|irreversible[^a-z]{0,4}approved|expand.?contract' "$mf" 2>/dev/null || { echo "RED [blocker]: $mf — destructive schema op (DROP/RENAME) with no reverse. Use expand-contract (add new → backfill → switch reads → drop LATER, as SEPARATE changes); if intentional, add a '-- down' reverse (a SQL comment) or an '-- irreversible: approved' marker."; fail=1; }
    fi
    if grep -IiE 'ADD COLUMN[^;]*NOT NULL' "$mf" 2>/dev/null | grep -qviE 'DEFAULT|GENERATED'; then
      echo "RED [blocker]: $mf — ADD COLUMN ... NOT NULL without a DEFAULT will fail on existing rows; add a DEFAULT or backfill in phases."; fail=1
    fi
  done <<< "$mig_files"
else echo "(no SQL migrations — skipping)"; fi
section "[12/13] Observability (structured logs, health, log hygiene)"
# Log hygiene runs on any source (a secret VALUE in a log is a [blocker]); server checks gate on a server app.
loghy=$(grep -rIinE '(console\.(log|info|warn|error|debug)|logger?\.[a-zA-Z]+|log\.(Info|Print|Printf|Debug|Error|Warn|Fatal)|logging\.(info|debug|warning|error)|print|println|fmt\.Print[a-z]*)[[:space:]]*\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null | grep -vE "${EXCL}|\.(test|spec)\." | grep -IiE '\.(password|passwd|secret|token|authorization|ssn|cvv|api[_-]?key|credit[_-]?card)\b|[$][{][^}]*(password|passwd|secret|token|ssn|cvv)|[{][[:space:]]*(password|passwd|secret|token|ssn|cvv)[[:space:]]*[,}]|[(][[:space:]]*(password|passwd|secret|token|ssn)[[:space:]]*[),]' | head -20 || true)
[ -n "$loghy" ] && { echo "RED [blocker]: a secret/PII VALUE appears in a log statement — never log passwords/tokens/secrets/PII:"; printf '%s\n' "$loghy" | head -10; fail=1; }
if xgrep_q -E '\.listen\(|createServer|app\.run\(|http\.ListenAndServe|uvicorn|FastAPI|express\(|fastify\(|gin\.(New|Default)|Flask\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' .; then
  xgrep_q -iE '/health|/healthz|/ready|/readyz|actuator/health|livenessProbe' . || echo "WARN [major]: no /health or /ready endpoint found — add liveness/readiness probes for a server app"
  grep -rIqiE 'winston|pino|bunyan|structlog|loguru|zap|logrus|zerolog|log/slog|slog\.' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null || echo "WARN [major]: no structured logger detected — use a structured logger (not raw console.log/print) in request paths"
  xgrep_q -iE 'correlation|request[_-]?id|x-request-id|traceparent|trace[_-]?id' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . || echo "WARN [major]: no request/correlation-ID found — attach one to every log line for traceability"
else echo "(not a server app — health/correlation checks skipped; log hygiene ran)"; fi
section "[13/13] Supply chain (deterministic installs, SBOM, pinned actions)"
if [ -f Containerfile ] || [ -d .github/workflows ]; then
  ndi=$(grep -rIinE '(npm|pnpm|yarn) +install' Containerfile .github/workflows 2>/dev/null | grep -viE 'npm ci|--frozen-lockfile|--ignore-scripts' | head -10 || true)
  [ -n "$ndi" ] && { echo "WARN [major]: non-deterministic install in a build — use 'npm ci' / 'pnpm i --frozen-lockfile' / 'pip install --require-hashes':"; printf '%s\n' "$ndi" | head -5; }
  fl=$(grep -rInE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@' .github/workflows 2>/dev/null | grep -vE 'uses:[[:space:]]*actions/' | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' | head -10 || true)
  [ -n "$fl" ] && { echo "WARN [major]: third-party GitHub Action pinned to a floating tag — pin by full commit SHA (uses: org/action@<40-hex-sha> # vX):"; printf '%s\n' "$fl" | head -5; }
  grep -rIqiE 'cyclonedx|spdx|sbom|syft|trivy' package.json Containerfile .github/workflows 2>/dev/null || echo "WARN [major]: no SBOM (CycloneDX/SPDX) generated — emit one as a build artifact for dependency transparency"
else echo "(no Containerfile or CI workflow — skipping supply-chain checks)"; fi
[ "$fail" = 0 ] && { echo -e "\nCI GREEN ($MODE)"; exit 0; } || { echo -e "\nCI RED ($MODE)"; exit 1; }

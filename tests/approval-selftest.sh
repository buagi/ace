#!/usr/bin/env bash
# approval-selftest.sh — the MERGE-APPROVAL gate (MERGE_APPROVAL=hermes). This is the only human check
# standing between an unattended loop and a merge to main, and it had NO test at all. Two properties:
#
#   1. `ace approve` (lib/scaffold.sh) is DENY-BY-DEFAULT and case-insensitive. Its caller is an LLM chat
#      relay, so it must release a merge ONLY on an explicit recognised approval word. Regression guarded:
#      the old code was `local d=yes` + a lowercase-only deny list, so "No", "nope", "stop", any free text,
#      and even a MISSING decision argument all recorded an APPROVAL and merged the PR.
#   2. `request_approval` (lib/autoloop.sh) reports an UNDELIVERED request as rc 2 ("unreachable human")
#      instead of swallowing the send failure and polling for APPROVAL_TIMEOUT (1h) for an answer to a
#      question nobody ever saw — and mints a token that is unique per REQUEST, not per PID+second.
#
# Hermetic: temp git repo, stubbed hermes, no network, no credits.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok=1; bad(){ echo "[approval] FAIL: $*"; ok=0; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT

############################ 1. ace approve — deny-by-default ############################
# Sourced the same way hygiene-selftest does: the real function, not a copy.
# shellcheck disable=SC1091
. "$ROOT/lib/core.sh" 2>/dev/null; . "$ROOT/lib/ui.sh" 2>/dev/null; . "$ROOT/lib/scaffold.sh" 2>/dev/null
type ace_approve >/dev/null 2>&1 || { echo "[approval] FAIL: ace_approve not defined after sourcing lib/scaffold.sh"; exit 1; }

repo="$d/repo"; mkdir -p "$repo"
( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) || exit 1
adir="$repo/.opencode/approvals"; mkdir -p "$adir"

# arm <tok> — put a fresh pending request in place and clear any previous answer.
arm(){ rm -f "$adir"/*.decision; printf 'kind=merge PR\nsummary=test\n' > "$adir/$1.request"; }
# decision_of — what `ace approve` recorded, or the literal string NONE when it wrote nothing.
decision_of(){ [ -f "$adir/$1.decision" ] && cat "$adir/$1.decision" || echo NONE; }

cd "$repo" || exit 1

# --- APPROVE set: the ONLY inputs allowed to release a merge (both arg forms, mixed case) ---------
for w in yes YES Yes y Y approve Approve APPROVE approved ok OK 1 ✅; do
  arm t1; ace_approve t1 "$w" </dev/null >/dev/null 2>&1
  [ "$(decision_of t1)" = yes ] || bad "two-arg '$w' must APPROVE, got '$(decision_of t1)'"
  # single-arg form (`ace approve yes` = newest pending) must agree with the two-arg form
  arm t1; ace_approve "$w" </dev/null >/dev/null 2>&1
  [ "$(decision_of t1)" = yes ] || bad "single-arg '$w' must APPROVE, got '$(decision_of t1)'"
done

# --- DENY set: explicit refusals, mixed case, AND arbitrary free text ------------------------------
# Everything outside the approve vocabulary is a deny — that is the whole point of fail-closed. Each of
# these previously recorded an APPROVAL and merged the PR to main. Multi-word entries are the realistic
# ones: a chat relay hands over whatever the human typed, not a tidy keyword.
deny_words=(no No NO n N nope Nope stop deny DENY denied reject rejected 0 ❌
            "hold off" "not now" "not yet" "no thanks" "maybe later" wait cancel
            "i changed my mind" "yes please" "sure thing" "what does that PR do?")
for w in "${deny_words[@]}"; do
  arm t2; ace_approve t2 "$w" </dev/null >/dev/null 2>&1
  [ "$(decision_of t2)" = no ] || bad "two-arg '$w' must DENY, got '$(decision_of t2)'"
done

# single-arg refusals must deny too (the token slot and the decision slot share one vocabulary)
for w in no No NO n deny denied reject rejected 0 ❌; do
  arm t2; ace_approve "$w" </dev/null >/dev/null 2>&1
  [ "$(decision_of t2)" = no ] || bad "single-arg '$w' must DENY, got '$(decision_of t2)'"
done

# --- MISSING decision: an error, NOT an approval --------------------------------------------------
# `ace approve <tok>` with no decision, and a bare `ace approve`, must both refuse to record anything.
arm t3; ace_approve t3 </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]                  || bad "ace approve <tok> with no decision must exit non-zero"
[ "$(decision_of t3)" = NONE ]   || bad "ace approve <tok> with no decision must record NOTHING, got '$(decision_of t3)'"
arm t3; ace_approve </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]                  || bad "bare ace approve must exit non-zero"
[ "$(decision_of t3)" = NONE ]   || bad "bare ace approve must record NOTHING, got '$(decision_of t3)'"
arm t3; ace_approve t3 "" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]                  || bad "empty-string decision must exit non-zero"
[ "$(decision_of t3)" = NONE ]   || bad "empty-string decision must record NOTHING, got '$(decision_of t3)'"

# --- malformed two-word reply must not let a leading approval word win ----------------------------
# `ace approve yes no` (a relay splitting "yes no thanks" badly): arg1 is the TOKEN slot, so the leading
# "yes" must NOT be promoted to the decision and override the trailing "no". No request named "yes"
# exists, so nothing is recorded at all.
arm t4; ace_approve yes no </dev/null >/dev/null 2>&1
[ "$(decision_of t4)" = NONE ] || bad "'ace approve yes no' must record NOTHING, got '$(decision_of t4)'"

cd "$ROOT" || exit 1

######################## 2. request_approval — delivery failure = rc 2 ########################
# lib/autoloop.sh RUNS the loop when sourced, so lift just the function out of it. The extraction is
# asserted non-empty and well-formed: if a refactor renames or reindents the function, this test turns
# CI red rather than silently testing nothing.
fn="$(awk '/^request_approval\(\)\{/,/^\}/' "$ROOT/lib/autoloop.sh")"
case "$fn" in
  request_approval*\}) : ;;
  *) echo "[approval] FAIL: could not extract request_approval() from lib/autoloop.sh"; exit 1 ;;
esac

# stub hermes: exit code driven by $STUB_RC, and every send appended to $MSGS so we can read the token
mkdir -p "$d/bin"
cat > "$d/bin/hermes" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MSGS"
exit "${STUB_RC:-0}"
STUB
chmod +x "$d/bin/hermes"
export PATH="$d/bin:$PATH" MSGS="$d/msgs"; : > "$MSGS"

work="$d/work"; mkdir -p "$work"; cd "$work" || exit 1
say(){ :; }; branch(){ echo feat/x; }        # loop helpers request_approval leans on
eval "$fn"

# --- delivery FAILURE must return 2 immediately (not stall for APPROVAL_TIMEOUT) ------------------
# APPROVAL_TIMEOUT is shortened to 20s purely to keep the test quick: in production it defaults to 3600,
# and the pre-fix code swallowed the send error and polled the WHOLE budget before reporting a timeout-
# deny. Asserting both the rc AND the elapsed time pins the real property — a human who was never asked
# must not cost the loop an hour. (A regression here costs this test 20s, not 60 minutes.)
: > "$MSGS"; t0=$(date +%s)
STUB_RC=1 APPROVAL_TIMEOUT=20 APPROVAL_POLL=2 request_approval "merge PR" "sum" </dev/null >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
[ "$rc" = 2 ] || bad "hermes send failure must return 2 (unreachable human), got rc=$rc"
[ "$el" -lt 5 ] || bad "send failure must fail FAST, waited ${el}s (it used to poll the whole APPROVAL_TIMEOUT)"
[ -z "$(ls .opencode/approvals/*.request 2>/dev/null)" ] || bad "a failed send must not leave a stale .request behind"

# --- no hermes binary at all is still rc 2 --------------------------------------------------------
( PATH="/nonexistent"; request_approval "merge PR" "sum" >/dev/null 2>&1; [ $? = 2 ] ) || bad "missing hermes binary must return 2"

# --- delivered + answered: yes approves, everything else denies ------------------------------------
# The stub answers the request the instant it is sent, so the first poll pass sees the decision.
cat > "$d/bin/hermes" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MSGS"
tok="$(printf '%s\n' "$*" | grep -oE 'ace approve [A-Za-z0-9-]+' | head -1 | awk '{print $3}')"
[ -n "$tok" ] && printf '%s\n' "$ANSWER" > ".opencode/approvals/$tok.decision"
exit 0
STUB
chmod +x "$d/bin/hermes"
# "<decision-file contents>|<expected rc>" — 0 approved, 1 denied. The loop side accepts the literal
# `yes` and NOTHING else (not even "YES"), because lowercase `yes` is the only approving string
# `ace approve` ever writes; anything else means the file was not written by the sanctioned path.
for row in "yes|0" "no|1" "nope|1" "YES|1" "|1"; do
  ans="${row%|*}"; want="${row##*|}"
  : > "$MSGS"
  ANSWER="$ans" APPROVAL_TIMEOUT=2 APPROVAL_POLL=1 request_approval "merge PR" "sum" </dev/null >/dev/null 2>&1; rc=$?
  [ "$rc" = "$want" ] || bad "decision file '$ans' must give rc=$want, got rc=$rc"
done

# --- token uniqueness: same PID, same second, must NOT repeat --------------------------------------
# The old token was the last 8 chars of "$(date +%s)$$" — PID-dominated, repeating every ~100s, so a new
# request could be answered by a STALE .decision left over from an earlier one. APPROVAL_TIMEOUT=0 skips
# the poll loop, so all 20 requests are minted inside the same second by the same PID.
: > "$MSGS"; rm -f "$d/bin/hermes"
cat > "$d/bin/hermes" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MSGS"
exit 0
STUB
chmod +x "$d/bin/hermes"
i=0; while [ "$i" -lt 20 ]; do
  APPROVAL_TIMEOUT=0 APPROVAL_POLL=1 request_approval "merge PR" "sum" >/dev/null 2>&1
  i=$((i+1))
done
n_tok="$(grep -oE 'ace approve [A-Za-z0-9-]+' "$MSGS" | awk '{print $3}' | sort -u | wc -l)"
[ "$n_tok" = 20 ] || bad "20 requests in the same second/PID produced only $n_tok distinct tokens (stale-decision collision risk)"

cd "$ROOT" || exit 1
[ "$ok" = 1 ] && { echo "[approval] PASS ✓"; exit 0; } || { echo "[approval] FAIL ✗"; exit 1; }

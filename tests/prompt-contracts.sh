#!/usr/bin/env bash
# prompt-contracts.sh — per-PR static regression gate for the 10 agent prompts (Part F / F3, Edit 1).
#
# The most damaging silent regression is a prompt edit that breaks an agent's OUTPUT CONTRACT — the
# verdict stops parsing, the file:line evidence requirement disappears, the abstention token vanishes, a
# read-only critic loses its task:deny — and the loop degrades quietly because the orchestrator can no
# longer read the verdict. This catches that in milliseconds, for zero tokens, on every PR.
#
# It extracts the generated opencode.json from write_opencode_config()'s heredoc, asserts the config
# stays valid JSON with no placeholder lost, and asserts each agent still carries its LOAD-BEARING
# clauses. The assertion list is built from Part-F STEP 0's verified-PRESENT set (LEDGER `## F0 — baseline`),
# NOT from guesses. House style: bash + jq only — no promptfoo/npm/python framework.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
IN=lib/install.sh
fail=0
bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "prompt-contracts: jq not found — cannot validate config"; exit 1; }
[ -f "$IN" ] || { echo "prompt-contracts: $IN not found"; exit 1; }

# --- 1. every placeholder survives (a lost placeholder = a broken generated config) ---
for ph in __PLUGINS__ __OPENAI_PROVIDER__ __OPENROUTER_PROVIDER__ __ORCH_MODEL__ __ORCH_OPTS__ __MAXCTX__ __EFF_MAIN__ __EFF_VERIFY__ __VERIFIER_MODEL__; do
  [ "$(grep -c -- "$ph" "$IN")" -gt 0 ] || bad "placeholder $ph missing from $IN (generated config would break)"
done

# --- 2. extract + stub + validate the generated config ---
# NB: use the single-quoted awk anchored on `opencode.json" <<` — the 00-START-HERE §4 awk embeds
# `$cfgdir`, which GNU awk parses as an end-of-line anchor (captures nothing). See LEDGER A1/F0.
JSON="$(awk '/opencode\.json" <</{f=1;next} /^JSON$/{f=0} f' "$IN" \
  | sed -e 's/__PLUGINS__/"x"/g' -e 's/__OPENAI_PROVIDER__//g' -e 's/__OPENROUTER_PROVIDER__//g' \
        -e 's#__ORCH_MODEL__#anthropic/claude-opus-x#g' -e 's/__ORCH_OPTS__/"x":"y"/g' \
        -e 's/__MAXCTX__/800000/g' -e 's/__EFF_MAIN__/max/g' -e 's/__EFF_VERIFY__/max/g' \
        -e 's/__VERIFIER_MODEL__/deepseek-v4-pro/g')"
echo "$JSON" | jq -e . >/dev/null 2>&1 || bad "generated opencode.json is not valid JSON (broken escaping in a prompt edit)"
NAGENTS="$(echo "$JSON" | jq -r '.agent | keys | length' 2>/dev/null || echo 0)"
[ "$NAGENTS" = 12 ] || bad "expected 12 agents in the generated config, got $NAGENTS"   # 10→11 researcher (Part H/H3), 11→12 debater

# --- helpers ---
has(){ # <agent> <fixed-string clause>
  local p; p="$(echo "$JSON" | jq -r ".agent.\"$1\".prompt // empty" 2>/dev/null)"
  printf '%s' "$p" | grep -qF -- "$2" || bad "$1 lost clause \"$2\" in $IN"
}
perm_deny(){ # <agent> — a read-only critic must keep task:deny (else it can spawn/act)
  [ "$(echo "$JSON" | jq -r ".agent.\"$1\".permission.task // \"-\"" 2>/dev/null)" = deny ] \
    || bad "$1 lost permission task:deny (a read-only critic must not be able to spawn subagents)"
}

# --- 3. per-agent load-bearing contracts (verified PRESENT in STEP 0 / F0 baseline) ---
# read-only critics keep task:deny
for a in verifier reviewer ux_reviewer standards_keeper alignment_reviewer launch_readiness_reviewer researcher debater; do perm_deny "$a"; done
# findings must cite concrete evidence (file:line)
for a in verifier reviewer ux_reviewer standards_keeper alignment_reviewer; do has "$a" "file:line"; done
# verifier: PASS/FAIL contract + the abstention token
has verifier "UNVERIFIED"; has verifier "PASS"
# implementer: scope discipline (diffs, not whole files)
has implementer "SCOPE:"
# test_engineer: adversarial mutation check (A3)
has test_engineer "MUTATION CHECK"
# engineering + product critics: the verdict token the orchestrator parses
has reviewer "APPROVE"; has ux_reviewer "APPROVE"
# numbered-procedure critics must NOT regress to prose + keep reason-first/verdict-last output
for a in standards_keeper alignment_reviewer; do has "$a" "PROCEDURE:"; has "$a" "reason first, verdict last"; done
# conflict_resolver: preserve-both-intents + abstention-is-success
has conflict_resolver "UNRESOLVABLE"; has conflict_resolver "INTENT and SEMANTICS"
# launch gate: NO-GO verdict + UNVERIFIED-is-a-fail
has launch_readiness_reviewer "NO-GO"; has launch_readiness_reviewer "UNVERIFIED"
# debater (cross-model debate): the good-faith rules + the machine-readable convergence contract
has debater "sycophantic"; has debater "GROUNDING IS MANDATORY"; has debater "ACCEPTED:"; has debater "CONVERGED:"; has debater "DIFFERENT LLM"
# the debate ENGINE + its transport/guards (fail-open, HIGH-risk-only, bounded) + the CLI route
[ -f lib/debate.sh ] || bad "lib/debate.sh (the debate engine) is missing"
grep -q 'opencode run --agent debater --model' lib/debate.sh || bad "debate.sh lost the read-only debater transport"
grep -q 'DEBATE_MODEL_B' lib/debate.sh || bad "debate.sh lost the OpenRouter challenger model resolution"
grep -q "risk:\[\[:space:\]\]\*HIGH" lib/debate.sh || bad "debate.sh lost the HIGH-risk-only guard (spec mode)"
grep -qE 'debate\)' ace || bad "ace dispatch lost the 'debate' command"
grep -q '__OPENROUTER_PROVIDER__' lib/install.sh || bad "install.sh lost the openrouter provider seam"
# SPEC_DEBATE auto-gate — both spec gates (coordinator + solo) run the debate on lint-GREEN HIGH-risk specs
grep -q 'SPEC_DEBATE' lib/swarm-run.sh || bad "coordinator spec gate lost the SPEC_DEBATE branch"
grep -q 'SPEC_DEBATE' lib/autoloop.sh || bad "solo spec gate lost the SPEC_DEBATE branch"
grep -q 'debate.sh" spec' lib/swarm-run.sh || bad "coordinator spec gate does not invoke the debate engine"
# REVIEW_DEBATE pre-merge gate — a cross-model pass over the branch diff before merge, fail-open, default OFF
grep -q 'REVIEW_DEBATE' lib/autoloop.sh || bad "merge_if_ready lost the REVIEW_DEBATE pre-merge gate"
grep -q 'debate.sh" review' lib/autoloop.sh || bad "REVIEW_DEBATE gate does not invoke the debate engine in review mode"
# debate trial: DEBATE_ONLY scoping + excessive metrics log + the report
grep -q 'DEBATE_ONLY' lib/debate.sh || bad "debate.sh lost the DEBATE_ONLY trial scoping"
grep -q 'debate-metrics.jsonl' lib/debate.sh || bad "debate.sh lost the metrics logging"
grep -q 'ace_debate_report' lib/debate.sh || bad "debate.sh lost the report/analysis function"
# debate EFFECTIVENESS: the labeled sandbox (ground truth) + the P/R/F1 scorer + the CLI
[ -f tests/debate-effectiveness.sh ] || bad "the debate effectiveness scorer is missing"
[ -f tests/debate-sandbox/labels.tsv ] || bad "the labeled debate sandbox (ground truth) is missing"
grep -q 'score)' ace || bad "ace debate lost the 'score' command"
grep -q 'ace_debate_trend' lib/debate.sh || bad "debate.sh lost the effectiveness trend/conclusion function"
grep -q 'ace_debate_testproject' lib/debate.sh || bad "debate.sh lost the runnable-sandbox materializer"
grep -q 'MODE=diagnose' tests/debate-effectiveness.sh || bad "the effectiveness harness lost the --diagnose (manual improvement) mode"
# orchestrator: the E-series sizing/resume clauses
has orchestrator "TASK-SIZE GATE"; has orchestrator "IMPLEMENTER-COUNT"; has orchestrator "RESUME DISCIPLINE"

# --- Part H / H2: research-first pipeline clauses (spec template · AC tracing · code-search grounding) ---
has orchestrator 'spec-template.md'
has orchestrator 'AC-ids'
has implementer  '.opencode/specs/<slug>.md'
has implementer  'Definition-of-Done'
grep -q 'CODE SEARCH LIES ON BIG FILES' "$IN" || bad "AGENTS.md heredoc lost the code-search grounding rule"
grep -q 'ace-spec-template v1' "$IN"          || bad "spec template heredoc/version tag missing from install.sh"
for h in '## 1. Problem' '## 3. Scope' '## 4. Acceptance criteria' '## 5. Integration (cited)' \
         '## 6. Increments' '## 7. Open questions'; do
  grep -qF "$h" "$IN" || bad "spec template lost mandatory heading: $h"
done
# autoloop drives (not in the JSON extract — assert on the file directly)
grep -q 'FILLING THE TEMPLATE' lib/autoloop.sh || bad "sync_objectives drive lost the template clause"
grep -q 'every .opencode/specs/\*.md' lib/autoloop.sh || bad "planner commit clause lost the spec-commit rule"

# --- Part H / H4: firecrawl research MCP + tool-shape routing + SSRF safety ---
jq -e '.mcp | keys | sort == ["context7","firecrawl","gitnexus","serena"]' <<<"$JSON" >/dev/null 2>&1 \
  || bad "mcp block keys drifted (expected context7+firecrawl+gitnexus+serena)"
grep -q 'RESEARCH TOOL-SHAPE' "$IN"      || bad "AGENTS.md lost the TOOL-SHAPE routing block"
grep -q 'NEVER firecrawl_crawl' "$IN"    || bad "AGENTS.md lost the crawl prohibition"
grep -q 'RESEARCH SAFETY (SSRF' "$IN"    || bad "AGENTS.md lost the SSRF research-safety rule"

# --- Part H / H5: spec gate — the re-spec drive must survive ---
grep -q 're-spec flagged feature specs' lib/autoloop.sh || bad "sync_objectives lost the SPECLINT_REPORT re-spec drive"
grep -q 'suffix -2 so you never overwrite' lib/autoloop.sh || bad "planner lost the slug-collision guard (H8 §6.8)"

# --- Part H unify (Phase 1): the SOLO path (par=1) runs the SAME spec gate + slice the swarm coordinator does ---
[ "$(grep -c 'spec_gate_solo' lib/autoloop.sh)" -ge 2 ] || bad "autoloop lost the solo spec-gate (def+call) — par=1 would skip the Part H lint/rubric"
[ "$(grep -c 'spec_slice_for' lib/autoloop.sh)" -ge 2 ] || bad "autoloop lost the solo spec-slice (def+call) — par=1 implementer would miss its frozen slice"
# --- Part H unify (Phase 2): one dashboard surface — every dash entry point routes through dash_auto ---
grep -q 'dash_auto()' lib/dash.sh || bad "dash.sh lost the unified dash_auto router"
[ "$(grep -c 'dash_auto' ace)" -ge 3 ] || bad "ace dispatch no longer routes all three dash entry points (loop/swarm/top-level) through dash_auto"
grep -q 'swarm_spec_lint' lib/swarm-run.sh || bad "swarm-run lost the pre-dispatch spec gate"

# --- Part H / H6: AC tracing (grammar order · ledger AC ids · verifier merge-time proof) ---
has orchestrator '(AC-2,AC-E1)'
has verifier 'ACCEPTANCE PROOF'
grep -q "placed BEFORE its 'Files:' hint" lib/autoloop.sh || bad "planner lost the Spec/AC-before-Files field ordering"
# H6 Edit 2: worker-dispatch spec slice — implementer reads it first; swarm-run assembles it fail-open
has implementer 'spec-slice.<slug>.md'
grep -q 'swarm_spec_slice' lib/swarm-run.sh || bad "swarm-run lost the _do_work spec-slice assembly"

# --- Part H / H3: the read-only researcher subagent (#11) — isolated spec drafting ---
has researcher 'read-only'
has researcher 'spec-template.md'
has researcher 'cites <path>:L'
has researcher 'UNVERIFIED'
jq -e '.agent.researcher.permission.edit == "deny" and .agent.researcher.permission.write == "deny" and .agent.researcher.permission.task == "deny"' \
  <<<"$JSON" >/dev/null 2>&1 || bad "researcher lost its read-only denies (edit/write/task must all be deny)"
has orchestrator 'RESEARCH DELEGATION'

# --- Part H / H7: spec freeze + prompt-cache prefix discipline ---
grep -q 'SPECS ARE FROZEN after the spec-gate' "$IN" || bad "AGENTS.md lost the spec-freeze / prompt-cache prefix rule (H7)"
# H5 Edit 5: optional LLM spec rubric — default OFF, fail-open, folded into the SPECGAP re-spec channel
grep -q 'swarm_spec_rubric' lib/swarm-run.sh || bad "swarm-run lost the optional spec-rubric gate hook"
grep -q 'SPEC_RUBRIC:-0' lib/swarm.sh || bad "swarm_spec_rubric lost its default-OFF guard (must make zero calls by default)"

if [ "$fail" = 0 ]; then
  echo "prompt-contracts: PASS — 12 agents, valid JSON, all placeholders + load-bearing clauses intact"
  exit 0
fi
echo "prompt-contracts: FAIL — a load-bearing agent clause regressed (see above)"
exit 1

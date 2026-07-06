#!/usr/bin/env bash
# swarm-wire.sh — wire the swarm into a live ACE project + opencode, idempotently.
#
#   bash lib/swarm-wire.sh check  <repo>   # dry-run: show what would change
#   bash lib/swarm-wire.sh apply  <repo>   # apply (backs up opencode.json first)
#
# Does five things (each idempotent, each skippable if already present):
#   1. MCP    — add the `swarm` MCP server to ~/.config/opencode/opencode.json so
#               every agent gets swarm_lease/wait/release/post/inbox/status.
#   2. RULES  — inject a SWARM pointer into the orchestrator + implementer prompts
#               ("if SWARM_WORKER is set, lease files before editing — see AGENTS.md").
#   3. FAST   — relax the auto-accept rail to a real low-risk fast-lane (P4): only
#               sensitive surfaces get the full 4-critic panel.
#   4. AGENTS — append the Swarm coordination protocol to <repo>/AGENTS.md.
#   5. COEX   — .gitattributes union-merge for append-only meta files.
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC="$HOME/.config/opencode/opencode.json"
MODE="${1:-check}"; REPO="${2:-$(git rev-parse --show-toplevel 2>/dev/null)}"
_apply(){ [ "$MODE" = apply ]; }
note(){ printf '  %-6s %s\n' "$1" "$2"; }

# swarm MCP command — resolves the ace lib at runtime (survives symlinked ace).
SWARM_CMD='["sh","-c","exec node \"$(dirname \"$(readlink -f \"$(command -v ace)\")\")/lib/swarm-mcp.js\""]'

FASTLANE_OLD='there is NO low-risk fast lane — treat EVERY change as HIGH-RISK (full panel + security hard gate)'
FASTLANE_NEW='the low-risk fast lane still applies to GENUINELY low-risk surfaces (docs/comments/config/copy/nav/test-only, no auth/money/order/migration/secret/public-API), but ANY change touching a sensitive surface is HIGH-RISK (full panel + security hard gate)'
SWARM_RULE=' SWARM: if the env var SWARM_WORKER is set you are ONE of several parallel flows sharing this repo — before editing any file you have not already leased, call swarm_lease(paths); if it returns "busy" do NOT edit (swarm_wait briefly or pick other work), and check swarm_inbox for flows asking you to release a file; see AGENTS.md "Swarm coordination".'

wire_opencode() {
  [ -f "$OC" ] || { note skip "no $OC"; return 0; }
  command -v jq >/dev/null || { note skip "jq missing"; return 0; }
  local changed=0 tmp; tmp="$(mktemp)"; cp "$OC" "$tmp"
  # 1. MCP
  if jq -e '.mcp.swarm' "$OC" >/dev/null 2>&1; then note mcp "swarm already registered"
  else note MCP "add swarm MCP server"; changed=1
       jq --argjson c "$SWARM_CMD" '.mcp.swarm = {type:"local", command:$c, enabled:true}' "$tmp" > "$tmp.1" && mv "$tmp.1" "$tmp"; fi
  # 2. RULES — append the swarm pointer to orchestrator + implementer prompts
  local a
  for a in orchestrator implementer; do
    if jq -e --arg a "$a" '.agent[$a].prompt | test("SWARM: if the env var SWARM_WORKER")' "$tmp" >/dev/null 2>&1; then
      note rule "$a prompt already has SWARM pointer"
    elif jq -e --arg a "$a" '.agent[$a].prompt' "$tmp" >/dev/null 2>&1; then
      note RULE "inject SWARM pointer into $a prompt"; changed=1
      jq --arg a "$a" --arg s "$SWARM_RULE" '.agent[$a].prompt += $s' "$tmp" > "$tmp.1" && mv "$tmp.1" "$tmp"
    fi
  done
  # 3. FAST-LANE — relax the rail in the orchestrator prompt
  if jq -e --arg o "$FASTLANE_OLD" '.agent.orchestrator.prompt | contains($o)' "$tmp" >/dev/null 2>&1; then
    note FAST "enable low-risk fast-lane (P4)"; changed=1
    jq --arg o "$FASTLANE_OLD" --arg n "$FASTLANE_NEW" '.agent.orchestrator.prompt |= (split($o) | join($n))' "$tmp" > "$tmp.1" && mv "$tmp.1" "$tmp"
  else note fast "fast-lane already applied (or clause not found)"; fi
  # validate + commit
  if jq -e . "$tmp" >/dev/null 2>&1; then
    if _apply && [ "$changed" = 1 ]; then cp "$OC" "$OC.bak.$(date +%s)"; mv "$tmp" "$OC"; note done "opencode.json updated (backup written)"
    else [ "$changed" = 1 ] && note DRY "opencode.json changes staged (run: apply)"; rm -f "$tmp"; fi
  else note ERROR "patched opencode.json failed jq validation — aborted"; rm -f "$tmp"; return 1; fi
}

wire_agents() {
  [ -n "$REPO" ] && [ -f "$REPO/AGENTS.md" ] || { note skip "no $REPO/AGENTS.md"; return 0; }
  if grep -q '^## Swarm coordination' "$REPO/AGENTS.md"; then note agents "protocol already present"; return 0; fi
  note AGENTS "append Swarm coordination protocol"
  _apply || return 0
  cat >> "$REPO/AGENTS.md" <<'MD'

## Swarm coordination (parallel flows)
When `SWARM_WORKER` is set, this repo is being worked by SEVERAL flows at once. Files are protected by **leases**: a flow may only edit paths it holds. Use the `swarm` MCP tools:
- **Before editing any file outside your lease** → `swarm_lease(paths)`. `ok` = safe to edit; `busy` = another flow holds it — do NOT edit.
- If `busy` and you truly need it → `swarm_wait(paths, timeout)`. On `timeout`, **defer** (finish/abandon and requeue) — never keep other leases while blocked (deadlock).
- Check `swarm_inbox()` for flows asking you to release a file; if you're done with it, `swarm_release`.
- Announce cross-cutting needs with `swarm_post(type, body)` (`touching`/`blocked`/`needs-attention`).
- Do NOT edit `ROADMAP.md` — the coordinator ticks items after merge. `lessons.md`/`changelog.md` are union-merged, so appending is safe.
MD
}

wire_coexist() { bash "$LIB/swarm-run.sh" coexist "$REPO" >/dev/null 2>&1 && note COEX "union-merge on lessons/changelog" || note coex "skipped"; }

wire_systemd() {
  local unit="$HOME/.config/systemd/user/ace-swarm.service"
  if [ -f "$unit" ]; then note systemd "ace-swarm.service present"; return 0; fi
  note SYSTEMD "write ace-swarm.service (disabled until you start it)"
  _apply || return 0
  mkdir -p "$(dirname "$unit")"
  { echo "[Unit]"; echo "Description=ACE swarm (parallel loop)"; echo "After=network-online.target"
    echo "StartLimitIntervalSec=600"; echo "StartLimitBurst=6"
    echo "[Service]"; echo "Type=simple"; echo "WorkingDirectory=$REPO"
    echo "Environment=SWARM_LIVE=1 DRY_RUN=0 SWARM_MAX=${SWARM_MAX:-4} SWARM_WATCH=1"
    echo "ExecStart=/usr/bin/env bash $LIB/swarm-run.sh start"
    echo "Restart=on-abnormal"; echo "RestartSec=20"; echo "OOMPolicy=continue"
    echo "MemoryAccounting=yes"; echo "MemoryLow=${LOOP_MEMORY_LOW:-1G}"
    echo "[Install]"; echo "WantedBy=default.target"; } > "$unit"
  systemctl --user daemon-reload 2>/dev/null || true
}

echo "swarm-wire ($MODE) · repo=$REPO"
wire_opencode; wire_agents; wire_coexist; wire_systemd
echo "swarm-wire: $([ "$MODE" = apply ] && echo applied || echo 'dry-run — re-run with: apply')"

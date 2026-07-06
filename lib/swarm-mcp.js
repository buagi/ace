#!/usr/bin/env node
/* swarm-mcp.js — MCP stdio server exposing the swarm coordination store to
 * opencode's agents (orchestrator + implementer + verifier + reviewers).
 *
 * Each flow launches opencode with its identity in env:
 *   SWARM_DIR   — the shared store   SWARM_WORKER — this flow's id   SWARM_HASH — its item
 * so every tool call acts on behalf of THAT flow. Thin JSON-RPC (newline-framed)
 * over stdio; each tool shells out to lib/swarm.sh (the single source of truth).
 *
 * Register in opencode.json:
 *   "swarm": { "type":"local", "command":["node","<ace>/lib/swarm-mcp.js"], "enabled":true }
 */
'use strict';
const { spawnSync } = require('child_process');
const path = require('path');
const SWARM = path.join(__dirname, 'swarm.sh');
const W = process.env.SWARM_WORKER || 'w?';
const H = process.env.SWARM_HASH || '';

// Hard-bounded shell-out: a single call can NEVER hang the MCP server (which would
// surface to opencode as a -32001 transport timeout). On spawn timeout, return '' so
// the caller maps it to a safe default (busy/timeout) — the agent always gets a reply.
const sh = (args, ms = 20000) => {
  const r = spawnSync('bash', [SWARM, ...args], { encoding: 'utf8', env: process.env, timeout: ms, killSignal: 'SIGKILL' });
  if (r.error && (r.error.code === 'ETIMEDOUT' || r.signal)) return '';
  return ((r.stdout || '') + (r.stderr || '')).trim();
};

const TOOLS = [
  { name: 'lease',
    description: 'BEFORE editing any file outside your current lease, call this to acquire/extend THIS flow\'s file-lease onto `paths`. Returns "ok" (yours — safe to edit) or "busy" (another flow holds an overlapping path — do NOT edit; either swarm_wait or pick other work).',
    inputSchema: { type: 'object', properties: { paths: { type: 'string', description: 'space-separated file/dir paths you intend to edit' } }, required: ['paths'] } },
  { name: 'wait',
    description: 'Block up to ~25s until `paths` are free, then lease them. Returns "ok" or "timeout". On "timeout" either re-call (if still needed and no deadlock risk) or DEFER (release + requeue) — never keep other leases while blocked (that risks deadlock).',
    inputSchema: { type: 'object', properties: { paths: { type: 'string' }, timeout: { type: 'number', default: 120 } }, required: ['paths'] } },
  { name: 'release',
    description: 'Release THIS flow\'s lease (once its item is merged or abandoned).',
    inputSchema: { type: 'object', properties: { status: { type: 'string', default: 'done' } } } },
  { name: 'post',
    description: 'Send a message on the swarm bus. to="" broadcasts to all flows; to="<worker>" directs it. Use for touching/blocked/handoff/needs-attention.',
    inputSchema: { type: 'object', properties: { type: { type: 'string' }, body: { type: 'string' }, to: { type: 'string', default: '' } }, required: ['type', 'body'] } },
  { name: 'inbox',
    description: 'Read recent messages addressed to this flow (or broadcast) — e.g. another flow asking you to release a file it needs.',
    inputSchema: { type: 'object', properties: { n: { type: 'number', default: 20 } } } },
  { name: 'status',
    description: 'Show active leases across all flows (who holds which paths right now).',
    inputSchema: { type: 'object', properties: {} } },
];

function call(name, a = {}) {
  switch (name) {
    // Every branch returns a NON-EMPTY string: an empty result renders as "Unknown"
    // in opencode and tells the agent nothing. On a spawn timeout sh() returns ''
    // → map to a safe, informative default (busy/timeout/retry).
    case 'lease':   return sh(['touch', W, H, a.paths || '']) || 'busy (store contended — swarm_wait or pick other work)';
    case 'wait': {  // cap the block so the MCP call returns inside opencode's client window; agent re-waits/defers if still busy
      const t = Math.min(Number(a.timeout) || 120, 25);
      return sh(['wait', W, H, a.paths || '', String(t)], (t + 8) * 1000) || 'timeout';
    }
    case 'release': return sh(['release', W, H, a.status || 'done']) || 'ok';
    case 'post':    return sh(['post', W, a.type || 'note', a.body || '', '', a.to || '', '']) || 'ok (posted)';
    case 'inbox':   return sh(['inbox', W, String(a.n || 20)]) || '(no messages for you)';
    case 'status':  return sh(['statusline']) || 'swarm: store busy — retry';
    default:              return `unknown tool ${name}`;
  }
}

const send = (o) => process.stdout.write(JSON.stringify(o) + '\n');

function handle(m) {
  if (m.method === 'initialize') {
    send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'swarm', version: '0.1.0' } } });
  } else if (m.method === 'tools/list') {
    send({ jsonrpc: '2.0', id: m.id, result: { tools: TOOLS } });
  } else if (m.method === 'tools/call') {
    const out = call(m.params && m.params.name, (m.params && m.params.arguments) || {});
    send({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: String(out) || '(ok)' }] } });
  } else if (m.method === 'ping') {
    send({ jsonrpc: '2.0', id: m.id, result: {} });
  } else if (m.id !== undefined && !String(m.method || '').startsWith('notifications/')) {
    send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'method not found' } });
  }
}

let buf = '';
process.stdin.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    try { handle(JSON.parse(line)); } catch (_) { /* ignore malformed */ }
  }
});
process.stdin.on('end', () => process.exit(0));

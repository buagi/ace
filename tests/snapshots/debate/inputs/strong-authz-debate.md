<!-- ace-spec-template v1 -->
# Spec: Per-object authorization   (slug: strong-authz · risk: HIGH · tier: FULL)
## 1. Problem
Endpoints taking a resource id must verify the caller owns THAT object (BOLA/IDOR), not merely be authenticated.
## 2. Prior art & approach
- OWASP API1:2023 Broken Object Level Authorization (source: https://owasp.org/API-Security/, 2026-07). DECISION: enforce per-object checks in middleware.
## 3. Scope
### In
- Add an ownership check to every `/orders/:id` route.
### Out
- Do NOT change authentication; do NOT touch admin routes here.
## 4. Acceptance criteria
- AC-1 GIVEN user A WHEN A requests user B's order THE SYSTEM SHALL return 404 (not 403 — no existence oracle).
- AC-E1 WHEN no session is present THE SYSTEM SHALL return 401.
## 5. Integration (cited)
- Files to touch: the auth middleware (cites lib/swarm.sh:L1-L6).
- Blast radius: all order routes.
## 6. Increments
1. scaffold check — files: lib/swarm.sh — ACs: AC-E1 — deps: —
2. enforce ownership — files: lib/swarm.sh — ACs: AC-1 — deps: 1
## 7. Open questions / assumptions
- None.
## C1. Contract
Deny by default; owner or admin only.
## C2. Data model
N/A — reads existing ownership column.
## C3. UX flow
N/A — API.
## C4. NFRs
No extra query per request (join on existing index).
## C5. Security
Default-deny; 404 for cross-tenant to avoid enumeration.
## C6. Risk & rollback
Behind `AUTHZ_STRICT`; revert to disable.

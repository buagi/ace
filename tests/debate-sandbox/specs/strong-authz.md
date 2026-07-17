<!-- ace-spec-template v1 -->
# Spec: Per-object order authz   (slug: strong-authz · risk: HIGH · tier: FULL)
## 1. Problem
GET /orders/:id must verify the caller owns THAT order (BOLA/IDOR), not merely be authenticated.
## 2. Prior art & approach
- OWASP API1:2023 BOLA (source: https://owasp.org/API-Security/, 2026-07). DECISION: per-object ownership check in middleware, default-deny.
## 3. Scope
### In
- Ownership check on /orders/:id before returning data.
### Out
- No admin override in this change.
## 4. Acceptance criteria
- AC-1 GIVEN user A WHEN A requests user B's order THE SYSTEM SHALL return 404 (no existence oracle).
- AC-2 WHEN the owner requests their order THE SYSTEM SHALL return 200.
- AC-E1 WHEN no session THE SYSTEM SHALL return 401.
## 5. Integration (cited)
- Files: the auth middleware (cites README.md:L1-L3). Blast radius: all order routes.
## 6. Increments
1. scaffold check — files: README.md — ACs: AC-E1 — deps: —
2. enforce ownership — files: README.md — ACs: AC-1,AC-2 — deps: 1
## 7. Open questions
- None.
## C1. Contract
Default-deny; owner-only; 404 cross-tenant.
## C2. Data model
Reads orders.user_id (existing).
## C3. UX flow
N/A — API.
## C4. NFRs
No extra query (join on existing index).
## C5. Security
Object-level authz; 404 to prevent enumeration; no PII in logs.
## C6. Risk & rollback
Behind AUTHZ_STRICT; revert to disable.

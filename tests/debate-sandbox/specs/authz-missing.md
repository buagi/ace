<!-- ace-spec-template v1 -->
# Spec: View order   (slug: authz-missing · risk: HIGH · tier: FULL)
## 1. Problem
Users view an order by id. Why now: launch.
## 2. Prior art & approach
- REST resource-by-id (source: https://restfulapi.net, 2026-07). DECISION: GET /orders/:id.
## 3. Scope
### In
- GET /orders/:id returns the order for an authenticated user.
### Out
- No editing.
## 4. Acceptance criteria
- AC-1 WHEN an authenticated user GETs /orders/:id THE SYSTEM SHALL return the order JSON.
- AC-E1 WHEN no session THE SYSTEM SHALL return 401.
## 5. Integration (cited)
- Files: the orders handler (cites README.md:L1-L2).
## 6. Increments
1. handler — files: README.md — ACs: AC-1,AC-E1
## 7. Open questions
- None.
## C1. Contract
GET /orders/:id → 200 order | 401.
## C2. Data model
orders(id, user_id, total).
## C3. UX flow
N/A.
## C4. NFRs
< 200ms.
## C5. Security
Requires a valid session.
## C6. Risk & rollback
Flag; revert.

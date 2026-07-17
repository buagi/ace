<!-- ace-spec-template v1 -->
# Spec: Faster dashboard   (slug: vague-acs · risk: HIGH · tier: FULL)
## 1. Problem
The dashboard feels slow.
## 2. Prior art & approach
- Caching (source: https://web.dev, 2026-07). DECISION: add a cache.
## 3. Scope
### In
- Make the dashboard faster.
### Out
- No redesign.
## 4. Acceptance criteria
- AC-1 WHEN a user opens the dashboard THE SYSTEM SHALL be fast.
- AC-2 WHEN there is a lot of data THE SYSTEM SHALL still work well.
## 5. Integration (cited)
- Files: the dashboard loader (cites README.md:L1-L2).
## 6. Increments
1. cache — files: README.md — ACs: AC-1,AC-2
## 7. Open questions
- None.
## C1. Contract
N/A.
## C2. Data model
A cache.
## C3. UX flow
N/A.
## C4. NFRs
Fast.
## C5. Security
N/A — no auth surface.
## C6. Risk & rollback
Revert.

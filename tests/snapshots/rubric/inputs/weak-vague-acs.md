<!-- ace-spec-template v1 -->
# Spec: Faster search   (slug: weak-vague-acs · risk: HIGH · tier: FULL)
## 1. Problem
Search feels slow.
## 2. Prior art & approach
- Algolia is fast (source: https://algolia.com, 2026-07). DECISION: add an index.
## 3. Scope
### In
- Make search faster.
### Out
- Not changing the UI.
## 4. Acceptance criteria
- AC-1 WHEN a user searches THE SYSTEM SHALL be fast.
- AC-2 WHEN there are many results THE SYSTEM SHALL work well.
## 5. Integration (cited)
- Files to touch: the search path (cites lib/swarm.sh:L1-L3).
## 6. Increments
1. add index — files: lib/swarm.sh — ACs: AC-1,AC-2 — deps: —
## 7. Open questions / assumptions
- None.
## C1. Contract
N/A.
## C2. Data model
An index, probably.
## C3. UX flow
N/A.
## C4. NFRs
Fast.
## C5. Security
N/A — no auth surface.
## C6. Risk & rollback
Revert.

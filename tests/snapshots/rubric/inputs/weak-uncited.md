<!-- ace-spec-template v1 -->
# Spec: Rate limiter   (slug: weak-uncited · risk: HIGH · tier: FULL)
## 1. Problem
Public endpoints get abused; add rate limiting.
## 2. Prior art & approach
- Token bucket is standard (source: https://en.wikipedia.org/wiki/Token_bucket, 2026-07). DECISION: token bucket.
## 3. Scope
### In
- Add a per-IP token bucket to public POST routes.
### Out
- Do NOT limit authenticated internal calls.
## 4. Acceptance criteria
- AC-1 WHEN a client exceeds 100 req/min THE SYSTEM SHALL return 429 with Retry-After.
- AC-E1 WHEN Redis is down THE SYSTEM SHALL fail open (allow) and alert.
## 5. Integration (cited)
- Files to touch: the middleware chain and the Redis client — the limiter sits before auth.
## 6. Increments
1. bucket — files: lib/swarm.sh — ACs: AC-1 — deps: —
2. fail-open — files: lib/swarm.sh — ACs: AC-E1 — deps: 1
## 7. Open questions / assumptions
- None.
## C1. Contract
429 + Retry-After header.
## C2. Data model
Redis counters, TTL 60s.
## C3. UX flow
N/A.
## C4. NFRs
< 1ms overhead per request.
## C5. Security
Limiter before auth so unauthenticated floods are capped.
## C6. Risk & rollback
Flag; revert.

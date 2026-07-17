<!-- ace-spec-template v1 -->
# Spec: Public rate limiter   (slug: strong-ratelimit · risk: HIGH · tier: FULL)
## 1. Problem
Public POST routes get abused; add per-IP rate limiting before auth.
## 2. Prior art & approach
- Token bucket (source: https://en.wikipedia.org/wiki/Token_bucket, 2026-07). DECISION: token bucket in middleware, before auth.
## 3. Scope
### In
- Per-IP token bucket on public POST routes; 429 + Retry-After.
### Out
- No limiting of authenticated internal calls.
## 4. Acceptance criteria
- AC-1 WHEN a client exceeds 100 req/min THE SYSTEM SHALL return 429 with Retry-After.
- AC-E1 WHEN Redis is unavailable THE SYSTEM SHALL fail open (allow) and alert.
## 5. Integration (cited)
- Files: the middleware chain (cites README.md:L1-L3). The limiter sits before auth.
## 6. Increments
1. bucket — files: README.md — ACs: AC-1 — deps: —
2. fail-open + alert — files: README.md — ACs: AC-E1 — deps: 1
## 7. Open questions
- None.
## C1. Contract
429 + Retry-After header.
## C2. Data model
Redis counters, TTL 60s.
## C3. UX flow
N/A.
## C4. NFRs
< 1ms overhead/request.
## C5. Security
Limiter before auth so unauthenticated floods are capped; no PII in counters.
## C6. Risk & rollback
Flag; revert.

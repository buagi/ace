<!-- ace-spec-template v1 -->
# Spec: Stripe webhook handler   (slug: strong-webhook · risk: HIGH · tier: FULL)
## 1. Problem
Payments must reconcile even under Stripe's at-least-once, out-of-order delivery. Why now: launch billing.
## 2. Prior art & approach
- Stripe's own guidance: verify signature on the raw body, dedupe by event id, fetch the object from the API (source: https://stripe.com/docs/webhooks, 2026-07). DECISION: match.
## 3. Scope
### In
- Verify signature; dedupe by event id; process `payment_intent.succeeded`.
### Out
- Do NOT handle refunds or subscription events here.
- Do NOT trust payload amounts (re-fetch from Stripe).
## 4. Acceptance criteria
- AC-1 WHEN a request arrives with an invalid signature THE SYSTEM SHALL return 400 and take no side effect.
- AC-2 WHEN a duplicate event id arrives THE SYSTEM SHALL no-op and return 200.
- AC-E1 WHEN events arrive out of order THE SYSTEM SHALL fetch the authoritative object rather than trust sequence.
## 5. Integration (cited)
- Files to touch: the webhook route (cites lib/swarm.sh:L1-L4).
- Blast radius: the payments ledger writer only.
## 6. Increments
1. verify+dedupe — files: lib/swarm.sh — ACs: AC-1,AC-2 — deps: —
2. reconcile fetch — files: lib/swarm.sh — ACs: AC-E1 — deps: 1
## 7. Open questions / assumptions
- None.
## C1. Contract
Raw body + `Stripe-Signature`; 2xx fast, heavy work async.
## C2. Data model
`processed_events(event_id PK, ts)` for dedupe.
## C3. UX flow
N/A — server to server.
## C4. NFRs
Return within 2s; retries idempotent.
## C5. Security
Signature verified on raw bytes before any DB write; no secrets logged.
## C6. Risk & rollback
Flag `WEBHOOKS_ON`; revert the commit to disable.

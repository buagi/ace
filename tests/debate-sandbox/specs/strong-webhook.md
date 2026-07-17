<!-- ace-spec-template v1 -->
# Spec: Stripe webhook (verified)   (slug: strong-webhook · risk: HIGH · tier: FULL)
## 1. Problem
Payments must reconcile under Stripe's at-least-once, out-of-order delivery.
## 2. Prior art & approach
- Stripe: verify signature on the raw body, dedupe by event id, refetch the object (source: https://stripe.com/docs/webhooks, 2026-07). DECISION: match.
## 3. Scope
### In
- Verify signature; dedupe by event id; process payment_intent.succeeded.
### Out
- No refunds / subscriptions here. Do NOT trust payload amounts.
## 4. Acceptance criteria
- AC-1 WHEN the signature is invalid THE SYSTEM SHALL return 400 and take no side effect.
- AC-2 WHEN a duplicate event id arrives THE SYSTEM SHALL no-op and return 200.
- AC-E1 WHEN events arrive out of order THE SYSTEM SHALL refetch the authoritative object.
## 5. Integration (cited)
- Files: the webhook route (cites README.md:L1-L4). Blast radius: the payments ledger writer.
## 6. Increments
1. verify+dedupe — files: README.md — ACs: AC-1,AC-2 — deps: —
2. reconcile refetch — files: README.md — ACs: AC-E1 — deps: 1
## 7. Open questions
- None.
## C1. Contract
Raw body + Stripe-Signature; 2xx fast, heavy work async.
## C2. Data model
processed_events(event_id PK, ts) for dedupe.
## C3. UX flow
N/A — server-to-server.
## C4. NFRs
Return < 2s; retries idempotent.
## C5. Security
Signature verified on raw bytes before any DB write; no secrets logged.
## C6. Risk & rollback
Flag WEBHOOKS_ON; revert to disable.

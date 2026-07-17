<!-- ace-spec-template v1 -->
# Spec: Payment webhook   (slug: weak-webhook-debate · risk: HIGH · tier: FULL)
## 1. Problem
Receive Stripe payment events. Why now: billing.
## 2. Prior art & approach
- Stripe webhooks (source: https://stripe.com/docs, 2026-07). DECISION: handle payment_intent.succeeded.
## 3. Scope
### In
- Handle payment_intent.succeeded; mark the order paid.
### Out
- No refunds.
## 4. Acceptance criteria
- AC-1 WHEN a payment_intent.succeeded arrives THE SYSTEM SHALL mark the order paid.
## 5. Integration (cited)
- Files to touch: the webhook handler (cites lib/swarm.sh:L1-L3). Reads the JSON body and updates the order.
## 6. Increments
1. handler — files: lib/swarm.sh — ACs: AC-1
## 7. Open questions
- None.
## C1. Contract
POST /webhook (JSON body) → 200.
## C2. Data model
orders(id, status).
## C3. UX flow
N/A.
## C4. NFRs
< 1s.
## C5. Security
N/A — internal endpoint.
## C6. Risk & rollback
Flag; revert.

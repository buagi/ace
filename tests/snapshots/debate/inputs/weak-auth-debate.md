<!-- ace-spec-template v1 -->
# Spec: Login   (slug: weak-auth-debate · risk: HIGH · tier: FULL)
## 1. Problem
Users need to log in. Why now: launch.
## 2. Prior art & approach
- OWASP session management (source: https://owasp.org, 2026-07). DECISION: cookie session.
## 3. Scope
### In
- Email+password login issuing a session cookie.
### Out
- No social login.
## 4. Acceptance criteria
- AC-1 WHEN valid credentials THE SYSTEM SHALL set a session cookie.
- AC-E1 WHEN a bad password THE SYSTEM SHALL return 401.
## 5. Integration (cited)
- Files to touch: the auth handler (cites lib/swarm.sh:L1-L4).
## 6. Increments
1. login — files: lib/swarm.sh — ACs: AC-1,AC-E1
## 7. Open questions
- None.
## C1. Contract
POST /login {email,password} → Set-Cookie.
## C2. Data model
sessions(id, user_id, created_at).
## C3. UX flow
Form → redirect.
## C4. NFRs
< 300ms.
## C5. Security
Password hashed with bcrypt.
## C6. Risk & rollback
Flag; revert.

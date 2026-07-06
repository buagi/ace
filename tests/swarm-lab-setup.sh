#!/usr/bin/env bash
# swarm-lab-setup.sh — build a throwaway ACE project engineered to BREAK the
# swarm: 10 complex features sharing hot files (money.ts×4, routes.ts×3,
# schema.ts×3, types.ts×2, positions/engine/quotes×2) so leases must serialize
# heavily while still parallelizing disjoint work. Creates a real git repo.
set -euo pipefail
LAB="${1:-$HOME/Desktop/code/swarm-lab}"
rm -rf "$LAB"; mkdir -p "$LAB"; cd "$LAB"
git init -q -b main; git config user.email swarm@lab; git config user.name swarm-lab

mkdir -p src/orders src/auth src/portfolio src/market src/db src/lib src/api src/audit migrations
for f in src/orders/engine.ts src/orders/types.ts src/orders/validate.ts \
         src/auth/session.ts src/auth/csrf.ts src/portfolio/positions.ts \
         src/market/feed.ts src/market/quotes.ts src/db/schema.ts src/lib/money.ts \
         src/api/routes.ts src/api/middleware.ts src/audit/viewer.ts; do
  printf '// %s — swarm-lab stub\nexport {};\n' "$f" > "$f"
done
echo 'exports.money = (c)=>c;' > src/lib/money.ts
cat > package.json <<'JSON'
{ "name": "swarm-lab", "version": "0.0.0", "private": true,
  "scripts": { "test": "node -e \"process.exit(0)\"", "build": "node -e \"process.exit(0)\"" } }
JSON
cat > ci.sh <<'SH'
#!/usr/bin/env bash
# trivial always-green gate (real project would build+test). Keeps LIVE runs cheap.
set -e; echo "ci: ok"; exit 0
SH
chmod +x ci.sh

# 10 features — each names its concrete files so the lease system has REAL overlaps.
cat > ROADMAP.md <<'MD'
# swarm-lab ROADMAP (adversarial: shared hot files force serialization)
- [ ] Idempotent order placement with audit log — src/orders/engine.ts src/orders/types.ts src/db/schema.ts src/api/routes.ts
- [ ] CSRF-hardened session auth with rotating tokens — src/auth/session.ts src/auth/csrf.ts src/api/routes.ts
- [ ] Decimal-safe position P&L accounting — src/portfolio/positions.ts src/lib/money.ts
- [ ] Order validation rules engine with limit checks — src/orders/validate.ts src/orders/types.ts src/lib/money.ts
- [ ] Market data feed failover and health tracking — src/market/feed.ts src/market/quotes.ts
- [ ] Quote normalization with currency conversion — src/market/quotes.ts src/lib/money.ts
- [ ] DB migration: trades table with composite indexes — src/db/schema.ts migrations/001_trades.sql
- [ ] REST API pagination and token-bucket rate limiting — src/api/routes.ts src/api/middleware.ts
- [ ] Portfolio rebalancing engine with drift bands — src/portfolio/positions.ts src/orders/engine.ts src/lib/money.ts
- [ ] Audit trail viewer with CSV export — src/audit/viewer.ts src/db/schema.ts
MD

cat > AGENTS.md <<'MD'
# swarm-lab
Test app for battle-testing the ACE swarm. Features deliberately share hot files.
MD

git add -A && git commit -q -m "chore: swarm-lab scaffold (10 adversarial features)"
echo "swarm-lab ready at $LAB"
echo "conflict graph (files shared by >1 feature):"
echo "  money.ts   → P&L, validation, quote-norm, rebalance (×4)"
echo "  routes.ts  → orders, auth, api-pagination (×3)"
echo "  schema.ts  → orders, migration, audit-viewer (×3)"
echo "  types.ts   → orders, validation (×2)  · positions/engine/quotes (×2 each)"

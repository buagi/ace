#!/usr/bin/env bash
# Build hardened, fully-static release binaries for the targets + hardening in .opencode/profile.yaml.
# Default: builds INSIDE a pinned golang container (reproducible, runs everywhere). --host builds on the host.
# Env overrides: HARDENING=none|standard|strong  TARGETS="linux/amd64 linux/arm64"  UPX=1  GOIMAGE=golang:<v>
#                VERSION=<tag>  SIGN=minisign|cosign  (minisign: MINISIGN_SECRET_KEY · cosign: COSIGN_KEY)
#
# Hardening ladder (Go binaries are inherently reversible — this raises cost, not immunity; keep secrets server-side):
#   none     -> plain build (version-stamped)
#   standard -> -trimpath -ldflags '-s -w -buildid='   (strip symbols/DWARF/paths/build-id)
#   strong   -> garble -literals -tiny   (obfuscate identifiers + string literals) on top of the strip
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
GO_V="$(awk '/^go [0-9]/{print $2; exit}' go.mod 2>/dev/null)"; GO_V="${GO_V:-1.23}"  # single source: go.mod
GOIMAGE="${GOIMAGE:-golang:$GO_V}"

prof(){ grep -E "^[[:space:]]*$1:[[:space:]]*" .opencode/profile.yaml 2>/dev/null | head -1 | sed -E "s/^[^:]*:[[:space:]]*\"([^\"]*)\".*$/\1/; t; s/^[^:]*:[[:space:]]*'([^']*)'.*$/\1/; t; s/^[^:]*:[[:space:]]*//; s/^#.*$//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//"; }
APP="${APP:-$(prof name)}"; [ -n "$APP" ] || APP="$(basename "$ROOT")"
HARDENING="${HARDENING:-$(prof hardening)}"; [ -n "$HARDENING" ] || HARDENING=standard
if [ -z "${TARGETS:-}" ]; then TARGETS="$(prof targets | tr -d '[]' | tr ',' ' ')"; fi
[ -n "${TARGETS:-}" ] || TARGETS="linux/amd64 linux/arm64"
# version stamp + reproducibility (both overridable)
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"; export SOURCE_DATE_EPOCH

HOST=0; for a in "$@"; do [ "$a" = "--host" ] && HOST=1; done
# 'strong' needs garble; if the host already has go+garble, build on the host (skips a slow in-container install).
if [ "$HOST" != 1 ] && [ "${RELEASE_INSIDE:-0}" != 1 ] && [ "$HARDENING" = strong ] \
   && command -v go >/dev/null 2>&1 && command -v garble >/dev/null 2>&1; then
  echo "[release] strong hardening + host go+garble present — building on the host (faster than an in-container install)."; HOST=1
fi
if [ "$HOST" != 1 ] && [ "${RELEASE_INSIDE:-0}" != 1 ]; then
  command -v podman >/dev/null 2>&1 || { echo "[release] podman not found — use --host to build on the host."; exit 1; }
  echo "[release] building inside $GOIMAGE (use --host to build on the host)…"
  # persistent module + build caches make repeat releases (and the garble install) fast.
  exec podman run --rm -v "$ROOT":/src:Z -w /src \
    -v ace-go-mod:/go/pkg/mod -v ace-go-build:/root/.cache/go-build \
    -e RELEASE_INSIDE=1 -e HARDENING="$HARDENING" -e TARGETS="$TARGETS" -e UPX="${UPX:-0}" -e APP="$APP" \
    -e VERSION="$VERSION" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e SIGN="${SIGN:-}" \
    "$GOIMAGE" bash scripts/release.sh --host
fi

# ---- host / inside-container: do the builds ----
export CGO_ENABLED=0 GOFLAGS=-buildvcs=false
export PATH="$(go env GOPATH 2>/dev/null)/bin:$PATH"
rm -rf dist; mkdir -p dist
LDFLAGS="-s -w -buildid= -X main.version=$VERSION"   # stripped + version-stamped

build_one(){ # <os> <arch>
  local os="$1" arch="$2" out="dist/${APP}_${os}_${arch}"; [ "$os" = windows ] && out="$out.exe"
  echo "[release] building $os/$arch  (hardening=$HARDENING, version=$VERSION)"
  case "$HARDENING" in
    none)
      GOOS="$os" GOARCH="$arch" go build -ldflags "-X main.version=$VERSION" -o "$out" ./cmd/"$APP" || return 1 ;;
    strong)
      command -v garble >/dev/null 2>&1 || { echo "[release] installing garble…"; go install mvdan.cc/garble@latest >/dev/null 2>&1 || true; }
      if command -v garble >/dev/null 2>&1; then
        GOOS="$os" GOARCH="$arch" garble -literals -tiny build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/"$APP" || return 1
      else
        echo "[release] WARN: garble unavailable — STRIPPED build (no obfuscation) for $os/$arch."
        GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/"$APP" || return 1
      fi ;;
    *) # standard
      GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/"$APP" || return 1 ;;
  esac
  if [ "${UPX:-0}" = 1 ]; then
    if command -v upx >/dev/null 2>&1; then upx --best --lzma "$out" >/dev/null 2>&1 || echo "[release] WARN: upx failed on $out";
    else echo "[release] WARN: UPX=1 but upx not installed — skipping packing for $out (upx is trivially reversible anyway)."; fi
  fi
  echo "[release]   -> $out"
}

rc=0
for t in $TARGETS; do
  os="${t%%/*}"; arch="${t#*/}"
  { [ -n "$os" ] && [ -n "$arch" ] && [ "$os" != "$t" ]; } || { echo "[release] bad target '$t' (want os/arch)"; rc=1; continue; }
  build_one "$os" "$arch" || { echo "[release] BUILD FAILED: $t"; rc=1; }
done
( cd dist && set -- $(ls 2>/dev/null | grep -v '^SHA256SUMS'); [ "$#" -gt 0 ] && { sha256sum "$@" 2>/dev/null || shasum -a 256 "$@" 2>/dev/null; } > SHA256SUMS ) 2>/dev/null || true
# optional signing of the checksum manifest (SIGN=minisign|cosign).
if [ -f dist/SHA256SUMS ] && [ -n "${SIGN:-}" ]; then
  case "$SIGN" in
    minisign) command -v minisign >/dev/null 2>&1 && minisign -Sm dist/SHA256SUMS ${MINISIGN_SECRET_KEY:+-s "$MINISIGN_SECRET_KEY"} >/dev/null 2>&1 \
                && echo "[release] signed dist/SHA256SUMS (minisign -> .minisig)" || echo "[release] WARN: minisign signing failed/unavailable." ;;
    cosign)   command -v cosign >/dev/null 2>&1 && cosign sign-blob --yes ${COSIGN_KEY:+--key "$COSIGN_KEY"} --output-signature dist/SHA256SUMS.sig dist/SHA256SUMS >/dev/null 2>&1 \
                && echo "[release] signed dist/SHA256SUMS (cosign -> SHA256SUMS.sig)" || echo "[release] WARN: cosign signing failed/unavailable." ;;
    *) echo "[release] WARN: unknown SIGN='$SIGN' (want minisign|cosign)." ;;
  esac
fi
echo "[release] artifacts:"; ls -lh dist 2>/dev/null | sed 's/^/  /'
echo "[release] hardening=$HARDENING  version=$VERSION  upx=${UPX:-0}  targets=$TARGETS"
{ [ "$HARDENING" = strong ] && ! command -v garble >/dev/null 2>&1; } && echo "[release] NOTE: 'strong' requested but garble missing — obfuscation was skipped; run 'ace install' or 'go install mvdan.cc/garble@latest'."
exit $rc

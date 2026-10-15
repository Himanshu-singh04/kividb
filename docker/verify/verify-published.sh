#!/usr/bin/env sh
# Same verification as verify.sh, but against already-published images for a
# given release tag rather than a from-source build. See
# docker-compose.published.yml for why this exists as a separate file rather
# than a --set override of docker-compose.yml.
#
# Usage: ./verify-published.sh <tag>          (e.g. ./verify-published.sh v1.0.4-rc1)
#        ./verify-published.sh <tag> <registry>   (default: ghcr.io/kividbio/kividb)
set -eu

cd "$(dirname "$0")"

TAG="${1:?usage: verify-published.sh <tag> [registry]}"
REGISTRY="${2:-ghcr.io/kividbio/kividb}"
export KIVIDB_IMAGE="${REGISTRY}:${TAG}"

command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "'docker compose' plugin not available" >&2; exit 1; }

echo "=== generating self-signed TLS cert ==="
sh ./gen-certs.sh

cleanup() {
    echo ""
    echo "=== tearing down ==="
    docker compose -f docker-compose.published.yml down -v --remove-orphans
}
trap cleanup EXIT

echo ""
echo "=== pulling all 4 published image variants for ${KIVIDB_IMAGE}(-tls|-lua|-full) ==="
docker compose -f docker-compose.published.yml pull

echo ""
echo "=== starting services ==="
docker compose -f docker-compose.published.yml up -d kividb-default kividb-tls kividb-lua kividb-full

echo ""
echo "=== running checks (see run-checks.sh) ==="
set +e
docker compose -f docker-compose.published.yml run --rm runner
result=$?
set -e

echo ""
echo "=== a build without TLS must refuse --tls-port ==="
. ./tls-refusal-check.sh
tls_refusal_check docker-compose.published.yml || result=1

echo ""
if [ "$result" -eq 0 ]; then
    echo "ALL CHECKS PASSED (published: ${KIVIDB_IMAGE})"
else
    echo "SOME CHECKS FAILED (published: ${KIVIDB_IMAGE}) — see PASS/FAIL lines above"
fi

exit "$result"

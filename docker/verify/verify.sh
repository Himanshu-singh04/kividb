#!/usr/bin/env sh
# End-to-end verification of the Docker image variants, ACL enforcement and pre-auth PING.
#
# Builds all 4 published kividb Docker image variants (default/-tls/-lua/-full)
# from the local Dockerfile, brings them up with a real ACL file + requirepass
# + self-signed TLS cert, and runs live redis-cli/openssl checks against them
# from inside the compose network — no host-side redis-cli/openssl required
# beyond what this script itself uses for setup.
#
# Usage: ./verify.sh   (run from this directory, or anywhere — cds itself)
set -eu

cd "$(dirname "$0")"

command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "'docker compose' plugin not available" >&2; exit 1; }

echo "=== generating self-signed TLS cert ==="
sh ./gen-certs.sh

cleanup() {
    echo ""
    echo "=== tearing down ==="
    docker compose down -v --remove-orphans
}
trap cleanup EXIT

echo ""
echo "=== building all 4 image variants (default / tls / lua / full) ==="
docker compose build

echo ""
echo "=== starting services ==="
docker compose up -d kividb-default kividb-tls kividb-lua kividb-full

echo ""
echo "=== running checks (see run-checks.sh) ==="
set +e
docker compose run --rm runner
result=$?
set -e

echo ""
echo "=== a build without TLS must refuse --tls-port ==="
. ./tls-refusal-check.sh
tls_refusal_check docker-compose.yml || result=1

echo ""
if [ "$result" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "SOME CHECKS FAILED — see PASS/FAIL lines above"
fi

exit "$result"

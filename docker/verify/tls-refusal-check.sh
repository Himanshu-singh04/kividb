#!/usr/bin/env sh
# Sourced by verify.sh and verify-published.sh.
#
# A build without the `tls` feature must refuse to start when it is given
# --tls-port. It used to accept the option and serve plaintext only — a
# deployment that asked for TLS and got none, with nothing to say so.
#
# This cannot be one of run-checks.sh's checks: those are made from another
# container, against servers that are running, and the point here is a
# server that does not start.
#
#   tls_refusal_check <compose-file>
#
# Returns 0 if both non-TLS variants refuse, 1 otherwise.

tls_refusal_check() {
    compose_file="$1"
    failed=0
    for service in kividb-default kividb-lua; do
        # 20 seconds: a build that does not refuse starts serving, and would
        # otherwise sit here until the job was cancelled.
        out=$(timeout 20 docker compose -f "$compose_file" run --rm --no-deps -T "$service" \
            --port 6380 --tls-port 6390 \
            --tls-cert-file /certs/server.crt --tls-key-file /certs/server.key 2>&1)
        code=$?
        if [ "$code" -ne 0 ] && [ "$code" -ne 124 ] \
            && echo "$out" | grep -q "built without TLS support"; then
            echo "PASS: $service (no tls feature): refuses to start with --tls-port"
        else
            echo "FAIL: $service (no tls feature): should refuse to start with --tls-port (exit=$code)"
            echo "$out" | tail -n 5
            failed=1
        fi
    done
    return "$failed"
}

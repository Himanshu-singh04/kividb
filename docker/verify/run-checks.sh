#!/bin/sh
# Runs inside the `runner` service (redis:7-alpine) against the 4 kividb-*
# services over the compose-internal network. See docker-compose.yml for the
# service topology and the section headers below for what
# each check corresponds to.
set -u

apk add --no-cache openssl >/dev/null 2>&1

PASS=0
FAIL=0

check() {
    # check <description> <0-for-expect-true|1-for-expect-false> <actual-exit-code>
    desc="$1"; want_zero="$2"; got="$3"
    if [ "$want_zero" = "0" ] && [ "$got" = "0" ]; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    elif [ "$want_zero" = "1" ] && [ "$got" != "0" ]; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (exit=$got, expected zero=$want_zero)"; FAIL=$((FAIL + 1))
    fi
}

wait_for_port() {
    host="$1"; port="$2"
    i=0
    while [ "$i" -lt 60 ]; do
        # -w 1: a name that does not resolve — a container that has exited —
        # otherwise costs several seconds an attempt, and sixty attempts at
        # that were most of half an hour.
        if nc -z -w 1 "$host" "$port" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "TIMEOUT waiting for $host:$port"
    return 1
}

rc() { # rc <host> <port> [redis-cli args...]
    host="$1"; port="$2"; shift 2
    redis-cli -h "$host" -p "$port" --no-raw "$@" 2>&1
}

tls_handshake_ok() { # tls_handshake_ok <host> <port>
    # A valid RESP reply of any kind (PONG, or NOAUTH since PING now requires
    # auth) proves the TLS handshake completed and the server
    # spoke RESP back over it — that's what this check is for, independent
    # of auth state.
    host="$1"; port="$2"
    out=$(printf '*1\r\n$4\r\nPING\r\n' | timeout 5 openssl s_client -connect "$host:$port" -CAfile /certs/server.crt -quiet 2>&1)
    echo "$out" | grep -qE "PONG|NOAUTH"
}

echo "=== waiting for services ==="
# The variants without the `tls` feature are started without a TLS port and
# have none to wait for.
for hp in "kividb-default 6380" \
          "kividb-tls 6380" "kividb-tls 6390" \
          "kividb-lua 6380" \
          "kividb-full 6380" "kividb-full 6390"; do
    wait_for_port $hp || true
done

echo ""
echo "=== Docker image variants must actually have the right features compiled in ==="

# TLS port must be LIVE only for variants built with the tls feature. (The
# other two are not even given one: nothing listens there.)
tls_handshake_ok kividb-default 6390
check "kividb-default (no tls feature): TLS handshake on tls-port should FAIL" 1 $?

tls_handshake_ok kividb-lua 6390
check "kividb-lua (no tls feature): TLS handshake on tls-port should FAIL" 1 $?

tls_handshake_ok kividb-tls 6390
check "kividb-tls (tls feature): TLS handshake on tls-port should SUCCEED" 0 $?

tls_handshake_ok kividb-full 6390
check "kividb-full (tls,lua features): TLS handshake on tls-port should SUCCEED" 0 $?

# EVAL must only work for variants built with the lua feature.
out=$(rc kividb-default 6380 -a adminpass EVAL "return 1" 0)
echo "$out" | grep -qi "unknown command\|ERR"
check "kividb-default (no lua feature): EVAL should be rejected" 0 $?

out=$(rc kividb-tls 6380 -a adminpass EVAL "return 1" 0)
echo "$out" | grep -qi "unknown command\|ERR"
check "kividb-tls (no lua feature): EVAL should be rejected" 0 $?

out=$(rc kividb-lua 6380 -a adminpass EVAL "return 1" 0)
echo "$out" | grep -q '(integer) 1'
check "kividb-lua (lua feature): EVAL should succeed" 0 $?

out=$(rc kividb-full 6380 -a adminpass EVAL "return 1" 0)
echo "$out" | grep -q '(integer) 1'
check "kividb-full (lua,tls features): EVAL should succeed" 0 $?

echo ""
echo "=== command ACL rules must be enforced live, not just via ACL DRYRUN ==="

out=$(rc kividb-default 6380 --user noflusher -a noflusherpass SET k v)
echo "$out" | grep -q "OK"
check "noflusher (+@all -flushall -flushdb): SET should succeed" 0 $?

out=$(rc kividb-default 6380 --user noflusher -a noflusherpass FLUSHALL)
echo "$out" | grep -qi "NOPERM"
check "noflusher (+@all -flushall -flushdb): FLUSHALL should be denied (NOPERM)" 0 $?

out=$(rc kividb-default 6380 --user noflusher -a noflusherpass FLUSHDB)
echo "$out" | grep -qi "NOPERM"
check "noflusher (+@all -flushall -flushdb): FLUSHDB should be denied (NOPERM)" 0 $?

echo ""
echo "=== PING must require auth when requirepass/ACL is set ==="

out=$(rc kividb-default 6380 PING)
echo "$out" | grep -qi "NOAUTH"
check "unauthenticated PING should be denied (NOAUTH)" 0 $?

echo ""
echo "=== readonly template (§5): -@write blocks writes, reads still work ==="

rc kividb-default 6380 --user noflusher -a noflusherpass SET seed value >/dev/null 2>&1

out=$(rc kividb-default 6380 --user analyst -a analystpass GET seed)
echo "$out" | grep -qi "NOPERM"
check "analyst (readonly): GET should NOT be denied" 1 $?

out=$(rc kividb-default 6380 --user analyst -a analystpass SET seed other)
echo "$out" | grep -qi "NOPERM"
check "analyst (readonly): SET should be denied (NOPERM)" 0 $?

echo ""
echo "=== load check: enforcement path holds up under redis-benchmark ==="

if redis-benchmark --help 2>&1 | grep -q -- "--user"; then
    echo "--- unrestricted 'default' user (RESTRICTED_CMD_CLIENTS stays 0 here) ---"
    redis-benchmark -h kividb-default -p 6380 -a adminpass -t set,get -n 50000 -q || true

    echo "--- restricted 'analyst' user (readonly; command-check now active) ---"
    redis-benchmark -h kividb-default -p 6380 -a analystpass --user analyst -t get -n 50000 -q || true
else
    echo "SKIP: this redis-benchmark build has no --user support; skipping ACL-user load check"
fi

echo ""
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

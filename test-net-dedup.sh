#!/bin/bash
# Regression test for the v1.2.0 --net deduplication fix.
#
# Reproduces the bug class without spinning up Docker:
#   Given a template field <Network>none</Network> AND an ExtraParams
#   entry that already specifies --net=container:X, the recreate step
#   must NOT emit `--net='none'` from the template field — that would
#   produce a duplicate --net flag which Docker 24+ rejects with exit
#   code 125 even though the container is created in a broken state.
#
# Usage:
#   ./test-net-dedup.sh
# Exit code 0 = pass, 1 = fail.
#
# Run after any change that touches the network-emit block in
# entrypoint.sh, or before pushing a new release.

set -uo pipefail

PASS=0
FAIL=0

# Inline copy of the network-emit logic from entrypoint.sh. Keep these
# in lockstep — if the regex changes there, mirror it here.
emit_net_flag() {
    local NETWORK="$1"
    local EXTRA_PARAMS="$2"
    if [ -n "$NETWORK" ]; then
        if echo "$EXTRA_PARAMS" | grep -qE '(^|[[:space:]])--net(work)?(=|[[:space:]])'; then
            return 0  # skip emit
        else
            echo "--net='${NETWORK}'"
            return 0
        fi
    fi
    return 0
}

assert() {
    local desc="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ ${desc}"
        PASS=$((PASS + 1))
    else
        echo "  ✗ ${desc}"
        echo "      expected: '${expected}'"
        echo "      actual:   '${actual}'"
        FAIL=$((FAIL + 1))
    fi
}

echo "Test: vpn-routed container (the original bug)"
result=$(emit_net_flag "none" "--net=container:vpn-gateway --health-cmd='curl -fSs / || exit 1'")
assert "ExtraParams has --net=container:X → suppress template Network" "$result" ""

echo
echo "Test: bridged container (no ExtraParams network)"
result=$(emit_net_flag "bridge" "--health-cmd='curl -fSs / || exit 1'")
assert "Bridge network with no --net in ExtraParams → emit template Network" "$result" "--net='bridge'"

echo
echo "Test: --network long-form alias"
result=$(emit_net_flag "none" "--network=container:vpn-gateway")
assert "ExtraParams uses --network= long-form → suppress" "$result" ""

echo
echo "Test: --net at start of ExtraParams (no leading whitespace)"
result=$(emit_net_flag "none" "--net=container:vpn-gateway")
assert "ExtraParams starts with --net → suppress" "$result" ""

echo
echo "Test: false-positive guard — --net-alias must not match"
result=$(emit_net_flag "bridge" "--net-alias=myalias")
assert "ExtraParams has --net-alias (not --net) → still emit Network" "$result" "--net='bridge'"

echo
echo "Test: false-positive guard — random text containing 'net='"
result=$(emit_net_flag "bridge" "-e MYVAR=net=foo")
assert "ExtraParams has 'net=' inside an env var → still emit Network" "$result" "--net='bridge'"

echo
echo "Test: empty Network field"
result=$(emit_net_flag "" "--net=container:vpn-gateway")
assert "Empty Network field → no emit (regardless of ExtraParams)" "$result" ""

echo
echo "Test: --net with space separator (rare but valid)"
result=$(emit_net_flag "none" "--net container:vpn-gateway")
assert "ExtraParams uses --net <value> with space → suppress" "$result" ""

echo
echo "================================"
echo "  ${PASS} passed, ${FAIL} failed"
echo "================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

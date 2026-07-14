#!/usr/bin/env bash
# deterministic grader: malformed input must be REJECTED (non-zero); valid pairs must still parse.
. ./parse.sh 2>/dev/null || { echo "no parse.sh"; exit 1; }
if parse "" >/dev/null 2>&1; then echo "FAIL: malformed input accepted"; exit 1; fi
[ "$(parse "port=3000")" = "3000" ] || { echo "FAIL: valid input broke"; exit 1; }
echo "PASS: rejects malformed, parses valid"; exit 0

#!/usr/bin/env bash
# tests/g19-v2-structural-check.sh
# Verifies the ci.yml workflow file structure to prevent theater execution.

set -u

WORKFLOW="$1"
if [ ! -f "$WORKFLOW" ]; then
  echo "G-19 FAIL: structural checker requires workflow file argument"
  exit 1
fi

CONTENT="$(cat "$WORKFLOW")"
FAILED=0

# 1. Missing run_gates id
if ! printf '%s\n' "$CONTENT" | grep -qE "id:[[:space:]]*run_gates"; then
  echo "G-19 FAIL: missing 'id: run_gates' in gate step"
  FAILED=1
fi

# 2. Missing sentinel checking steps.run_gates.outcome
if ! printf '%s\n' "$CONTENT" | grep -qE "steps\.run_gates\.outcome"; then
  echo "G-19 FAIL: missing sentinel checking steps.run_gates.outcome"
  FAILED=1
fi

# 2b. Missing sentinel checking VT_G19_EXEC_PROOF
if ! printf '%s\n' "$CONTENT" | grep -qE "VT_G19_EXEC_PROOF"; then
  echo "G-19 FAIL: missing sentinel checking VT_G19_EXEC_PROOF"
  FAILED=1
fi

# 3. if: ${{ false }} on gate execution or anywhere
if printf '%s\n' "$CONTENT" | grep -qE "if:[[:space:]]*\\$\\{\\{[[:space:]]*false[[:space:]]*\\}\\}"; then
  echo "G-19 FAIL: 'if: \${{ false }}' found (theater prevention)"
  FAILED=1
fi

# 4. continue-on-error on gate execution or sentinel
if printf '%s\n' "$CONTENT" | grep -qE "^[[:space:]]*continue-on-error[[:space:]]*:"; then
  echo "G-19 FAIL: 'continue-on-error' found"
  FAILED=1
fi

# 5. folded scalar run: > for the gate command
if printf '%s\n' "$CONTENT" | grep -qE "^[[:space:]]*run:[[:space:]]*>[[:space:]]*$"; then
  echo "G-19 FAIL: folded scalar 'run: >' found (must use literal blocks)"
  FAILED=1
fi

# 6. neutralizers including || true, || true), ; true, ; exit 0
NEUTRALIZERS="$(printf '%s\n' "$CONTENT" | grep -nE '^[[:space:]]*continue-on-error[[:space:]]*:|(^|[[:space:]])set[[:space:]]+\+e([[:space:]]|$)|\|\|[[:space:]]*(true|:)([[:space:]]|\)|;|$)|;[[:space:]]*(true|exit[[:space:]]+0)([[:space:]]|\)|;|$)' || true)"
if [ -n "$NEUTRALIZERS" ]; then
  echo "G-19 FAIL: workflow contains gate-neutralizing pattern(s)"
  printf '%s\n' "$NEUTRALIZERS"
  FAILED=1
fi

if [ "$FAILED" -eq 1 ]; then
  exit 1
else
  echo "G-19 STRUCTURAL CHECK PASS"
  exit 0
fi

#!/usr/bin/env bash
# Verifies the CI gate path proves real execution rather than YAML presence.

set -u

WORKFLOW="${1:-}"
if [ -z "$WORKFLOW" ] || [ ! -f "$WORKFLOW" ]; then
  echo "G-19 FAIL: structural checker requires workflow file argument"
  exit 1
fi

FAILED=0
fail() {
  echo "G-19 FAIL: $1"
  FAILED=1
}

CONTENT="$(cat "$WORKFLOW")"

step_count() {
  awk -v name="$1" '
    /^[[:space:]]*- name:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*- name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == name) count++
    }
    END { print count + 0 }
  ' "$WORKFLOW"
}

extract_step() {
  awk -v name="$1" '
    /^[[:space:]]*- name:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*- name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (capture) exit
      if (line == name) {
        capture = 1
        print
        next
      }
    }
    capture { print }
  ' "$WORKFLOW"
}

GATE_STEP_NAME="Run verification gate suite"
SENTINEL_STEP_NAME="G-19 CI anti-theater (run-gates execution proof required)"

GATE_STEP_COUNT="$(step_count "$GATE_STEP_NAME")"
[ "$GATE_STEP_COUNT" -eq 1 ] || fail "expected exactly one '$GATE_STEP_NAME' step, found $GATE_STEP_COUNT"

SENTINEL_STEP_COUNT="$(step_count "$SENTINEL_STEP_NAME")"
[ "$SENTINEL_STEP_COUNT" -eq 1 ] || fail "expected exactly one '$SENTINEL_STEP_NAME' step, found $SENTINEL_STEP_COUNT"

GATE_BLOCK="$(extract_step "$GATE_STEP_NAME")"
SENTINEL_BLOCK="$(extract_step "$SENTINEL_STEP_NAME")"

if ! printf '%s\n' "$GATE_BLOCK" | grep -qE '^[[:space:]]*id:[[:space:]]*run_gates[[:space:]]*$'; then
  fail "gate execution step is missing id: run_gates"
fi

GATE_EXEC_LINES="$(
  printf '%s\n' "$GATE_BLOCK" | awk '
    /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ {
      in_run = 1
      next
    }
    in_run {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") print line
    }
  '
)"

RUN_GATES_CALLS="$(
  printf '%s\n' "$GATE_EXEC_LINES" | awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "bash tests/run-gates.sh") count++
    }
    END { print count + 0 }
  '
)"
[ "$RUN_GATES_CALLS" -eq 1 ] || fail "expected exactly one literal bash tests/run-gates.sh command in gate step, found $RUN_GATES_CALLS"

if [ "$GATE_EXEC_LINES" != "bash tests/run-gates.sh" ]; then
  fail "gate run block must contain exactly one executable line: bash tests/run-gates.sh"
fi

if printf '%s\n%s\n' "$GATE_BLOCK" "$SENTINEL_BLOCK" | grep -qE '^[[:space:]]*if:[[:space:]]*(false|\$\{\{[^}]*false[^}]*\}\})[[:space:]]*$'; then
  fail "if:false guard found on G-19 execution path"
fi

if printf '%s\n%s\n' "$GATE_BLOCK" "$SENTINEL_BLOCK" | grep -qE '^[[:space:]]*continue-on-error[[:space:]]*:'; then
  fail "continue-on-error found on G-19 execution path"
fi

if printf '%s\n%s\n' "$GATE_BLOCK" "$SENTINEL_BLOCK" | grep -qE '^[[:space:]]*run:[[:space:]]*>[[:space:]]*$'; then
  fail "folded scalar run: > found on G-19 execution path; gate command must not be foldable"
fi

if printf '%s\n%s\n' "$GATE_BLOCK" "$SENTINEL_BLOCK" | grep -qF 'GITHUB_OUTPUT'; then
  fail "workflow must not write execution proof directly through GITHUB_OUTPUT"
fi

NEUTRALIZERS="$(printf '%s\n%s\n' "$GATE_BLOCK" "$SENTINEL_BLOCK" | grep -nE '(^|[[:space:]])set[[:space:]]+\+e([[:space:]]|$)|\|\|[[:space:]]*(true|:)([[:space:]]|\)|;|$)|;[[:space:]]*(true|exit[[:space:]]+0)([[:space:]]|\)|;|$)' || true)"
if [ -n "$NEUTRALIZERS" ]; then
  fail "G-19 execution path contains gate-neutralizing pattern(s)"
  printf '%s\n' "$NEUTRALIZERS"
fi

if ! printf '%s\n' "$SENTINEL_BLOCK" | grep -qE '^[[:space:]]*if:[[:space:]]*always\(\)[[:space:]]*$'; then
  fail "missing if: always() execution sentinel"
fi

if ! printf '%s\n' "$SENTINEL_BLOCK" | grep -qF 'steps.run_gates.outcome'; then
  fail "sentinel does not assert steps.run_gates.outcome"
fi

if ! printf '%s\n' "$SENTINEL_BLOCK" | grep -qF 'steps.run_gates.outputs.vt_g19_exec_proof'; then
  fail "sentinel does not read vt_g19_exec_proof output"
fi

if ! printf '%s\n' "$SENTINEL_BLOCK" | grep -qF '^[0-9a-f]{64}$'; then
  fail "sentinel does not validate a 64-hex execution proof"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "G-19 STRUCTURAL CHECK PASS"
  exit 0
fi

exit 1

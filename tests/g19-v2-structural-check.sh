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

extract_job() {
  awk '
    /^[[:space:]]*gates:[[:space:]]*$/ {
      indent = match($0, /[^[:space:]]/) - 1
      capture = 1
      print
      next
    }
    capture {
      if ($0 ~ /^[[:space:]]*$/) {
        print
        next
      }
      current_indent = match($0, /[^[:space:]]/) - 1
      if (current_indent <= indent) exit
      print
    }
  ' "$WORKFLOW"
}

run_exec_lines() {
  awk '
    /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ {
      in_run = 1
      next
    }
    in_run {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (line ~ /^#/) next
      print line
    }
  '
}

GATE_STEP_NAME="Run verification gate suite"
SENTINEL_STEP_NAME="G-19 CI anti-theater (run-gates execution proof required)"

GATE_STEP_COUNT="$(step_count "$GATE_STEP_NAME")"
[ "$GATE_STEP_COUNT" -eq 1 ] || fail "expected exactly one '$GATE_STEP_NAME' step, found $GATE_STEP_COUNT"

SENTINEL_STEP_COUNT="$(step_count "$SENTINEL_STEP_NAME")"
[ "$SENTINEL_STEP_COUNT" -eq 1 ] || fail "expected exactly one '$SENTINEL_STEP_NAME' step, found $SENTINEL_STEP_COUNT"

GATE_BLOCK="$(extract_step "$GATE_STEP_NAME")"
SENTINEL_BLOCK="$(extract_step "$SENTINEL_STEP_NAME")"
GATES_JOB_BLOCK="$(extract_job)"
GATES_JOB_CONTROLS="$(
  printf '%s\n' "$GATES_JOB_BLOCK" | awk '
    /^[[:space:]]*steps:[[:space:]]*$/ { exit }
    { print }
  '
)"

if ! printf '%s\n' "$GATE_BLOCK" | grep -qE '^[[:space:]]*id:[[:space:]]*run_gates[[:space:]]*$'; then
  fail "gate execution step is missing id: run_gates"
fi

GATE_EXEC_LINES="$(printf '%s\n' "$GATE_BLOCK" | run_exec_lines)"
SENTINEL_EXEC_LINES="$(printf '%s\n' "$SENTINEL_BLOCK" | run_exec_lines)"

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

if printf '%s\n' "$GATES_JOB_CONTROLS" | grep -qE '^[[:space:]]*if[[:space:]]*:'; then
  fail "job-level if guard found on gates job"
fi

if printf '%s\n' "$GATES_JOB_CONTROLS" | grep -qE '^[[:space:]]*continue-on-error[[:space:]]*:'; then
  fail "job-level continue-on-error found on gates job"
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

TRAP_NEUTRALIZERS="$(printf '%s\n%s\n' "$GATE_EXEC_LINES" "$SENTINEL_EXEC_LINES" | grep -nE '(^|[[:space:]])trap([[:space:]]|$)' || true)"
if [ -n "$TRAP_NEUTRALIZERS" ]; then
  fail "G-19 execution path contains trap neutralizer(s)"
  printf '%s\n' "$TRAP_NEUTRALIZERS"
fi

if ! printf '%s\n' "$SENTINEL_BLOCK" | grep -qE '^[[:space:]]*if:[[:space:]]*always\(\)[[:space:]]*$'; then
  fail "missing if: always() execution sentinel"
fi

if ! printf '%s\n' "$SENTINEL_EXEC_LINES" | grep -qE '^[[:space:]]*if[[:space:]]+\[[[:space:]]*"\$\{\{[[:space:]]*steps\.run_gates\.outcome[[:space:]]*\}\}"[[:space:]]*!=[[:space:]]*"success"[[:space:]]*\][;[:space:]]*then[[:space:]]*$'; then
  fail "sentinel does not assert steps.run_gates.outcome"
fi

if ! printf '%s\n' "$SENTINEL_EXEC_LINES" | grep -qE '^[[:space:]]*PROOF="\$\{\{[[:space:]]*steps\.run_gates\.outputs\.vt_g19_exec_proof[[:space:]]*\}\}"[[:space:]]*$'; then
  fail "sentinel does not read vt_g19_exec_proof output"
fi

if ! printf '%s\n' "$SENTINEL_EXEC_LINES" | grep -qE "grep[[:space:]]+-qE[[:space:]]+'\\^\\[0-9a-f\\]\\{64\\}\\$'"; then
  fail "sentinel does not validate a 64-hex execution proof"
fi

if printf '%s\n' "$SENTINEL_EXEC_LINES" | grep -qE '^[[:space:]]*(true|:|exit[[:space:]]+0)[[:space:]]*$'; then
  fail "sentinel contains inert success command"
fi

BAD_SENTINEL_EXITS="$(
  printf '%s\n' "$SENTINEL_EXEC_LINES" | awk '
    /^[[:space:]]*exit([[:space:]]+.*)?$/ && $0 !~ /^[[:space:]]*exit[[:space:]]+1[[:space:]]*$/ { print }
  '
)"
if [ -n "$BAD_SENTINEL_EXITS" ]; then
  fail "sentinel failure branches must terminate with literal exit 1"
  printf '%s\n' "$BAD_SENTINEL_EXITS"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "G-19 STRUCTURAL CHECK PASS"
  exit 0
fi

exit 1

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
  printf '%s\n' "$GATES_JOB_BLOCK" | awk -v name="$1" '
    /^[[:space:]]*- name:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*- name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == name) count++
    }
    END { print count + 0 }
  '
}

extract_step() {
  printf '%s\n' "$GATES_JOB_BLOCK" | awk -v name="$1" '
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
  '
}

extract_job() {
  awk '
    function line_indent(value) {
      match(value, /[^[:space:]]/)
      return RSTART ? RSTART - 1 : -1
    }
    /^[[:space:]]*jobs:[[:space:]]*$/ {
      jobs_indent = line_indent($0)
      in_jobs = 1
      next
    }
    in_jobs {
      if ($0 ~ /^[[:space:]]*$/) {
        if (capture) print
        next
      }
      current_indent = line_indent($0)
      if (current_indent <= jobs_indent) exit
      if (current_indent == jobs_indent + 2 && $0 ~ /^[[:space:]]*["\047]?gates["\047]?[[:space:]]*:/) {
        indent = current_indent
      capture = 1
      print
      next
    }
      if (capture && current_indent <= indent) exit
      if (capture) print
    }
  ' "$WORKFLOW"
}

control_key_present() {
  printf '%s\n' "$GATES_JOB_CONTROLS" | awk -v key="$1" '
    {
      line = $0
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      if (line ~ "^[[:space:]]*" key "[[:space:]]*:") found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

step_control_key_present() {
  printf '%s\n' "$1" | awk -v key="$2" '
    {
      line = $0
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      if (line ~ "^[[:space:]]*" key "[[:space:]]*:") found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

sentinel_branch_exits_one() {
  printf '%s\n' "$SENTINEL_EXEC_LINES" | awk -v branch="$1" '
    function starts_branch(line) {
      if (branch == "outcome") {
        return line ~ /^[[:space:]]*if[[:space:]]+/ && line ~ /steps\.run_gates\.outcome/ && line ~ /!=/ && line ~ /success/ && line ~ /then[[:space:]]*$/
      }
      if (branch == "missing-proof") {
        return line ~ /^[[:space:]]*if[[:space:]]+/ && line ~ /-z/ && line ~ /\$PROOF/ && line ~ /then[[:space:]]*$/
      }
      if (branch == "invalid-proof") {
        return line ~ /^[[:space:]]*if[[:space:]]+!/ && line ~ /grep[[:space:]]+-qE/ && line ~ /\^\[0-9a-f\]\{64\}\$/ && line ~ /then[[:space:]]*$/
      }
      return 0
    }
    BEGIN { rc = 1 }
    starts_branch($0) {
      in_branch = 1
      depth = 1
      found_exit = 0
      next
    }
    in_branch {
      if (depth == 1 && $0 ~ /^[[:space:]]*exit[[:space:]]+1[[:space:]]*$/) found_exit = 1
      if ($0 ~ /^[[:space:]]*if[[:space:]]+/) depth++
      if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
        depth--
        if (depth == 0) {
          rc = found_exit ? 0 : 1
          exit
        }
      }
    }
    END { exit rc }
  '
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

GATES_JOB_BLOCK="$(extract_job)"
if [ -z "$GATES_JOB_BLOCK" ]; then
  fail "jobs.gates job block was not found"
fi

GATE_STEP_COUNT="$(step_count "$GATE_STEP_NAME")"
[ "$GATE_STEP_COUNT" -eq 1 ] || fail "expected exactly one '$GATE_STEP_NAME' step, found $GATE_STEP_COUNT"

SENTINEL_STEP_COUNT="$(step_count "$SENTINEL_STEP_NAME")"
[ "$SENTINEL_STEP_COUNT" -eq 1 ] || fail "expected exactly one '$SENTINEL_STEP_NAME' step, found $SENTINEL_STEP_COUNT"

GATE_BLOCK="$(extract_step "$GATE_STEP_NAME")"
SENTINEL_BLOCK="$(extract_step "$SENTINEL_STEP_NAME")"
GATES_JOB_CONTROLS="$(
  printf '%s\n' "$GATES_JOB_BLOCK" | awk '
    NR == 1 {
      gate_indent = match($0, /[^[:space:]]/) - 1
      control_indent = gate_indent + 2
      next
    }
    {
      current_indent = match($0, /[^[:space:]]/) - 1
      if (current_indent == control_indent && $0 ~ /^[[:space:]]*["\047]?(if|continue-on-error|needs)["\047]?[[:space:]]*:/) print
    }
  '
)"

GATES_JOB_HEADER="$(printf '%s\n' "$GATES_JOB_BLOCK" | sed -n '1p')"
if printf '%s\n' "$GATES_JOB_HEADER" | grep -qE '^[[:space:]]*["'\'']?gates["'\'']?[[:space:]]*:[[:space:]]*\*'; then
  fail "jobs.gates must not be a YAML alias"
fi

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

if step_control_key_present "$GATE_BLOCK" "if"; then
  fail "gate execution step must not define an if guard"
fi

if step_control_key_present "$GATE_BLOCK" "continue-on-error"; then
  fail "gate execution step must not define continue-on-error"
fi

if control_key_present "if"; then
  fail "job-level if guard found on gates job"
fi

if control_key_present "continue-on-error"; then
  fail "job-level continue-on-error found on gates job"
fi

if control_key_present "needs"; then
  fail "job-level needs found on gates job"
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

HEREDOC_MARKERS="$(printf '%s\n%s\n' "$GATE_EXEC_LINES" "$SENTINEL_EXEC_LINES" | grep -nE '<<-?[[:space:]]*["'\''"]?[A-Za-z_][A-Za-z0-9_]*["'\''"]?' || true)"
if [ -n "$HEREDOC_MARKERS" ]; then
  fail "G-19 execution path contains heredoc inert text"
  printf '%s\n' "$HEREDOC_MARKERS"
fi

FUNCTION_DEFS="$(printf '%s\n%s\n' "$GATE_EXEC_LINES" "$SENTINEL_EXEC_LINES" | grep -nE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{|function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*)' || true)"
if [ -n "$FUNCTION_DEFS" ]; then
  fail "G-19 execution path contains uncalled shell function text"
  printf '%s\n' "$FUNCTION_DEFS"
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

if ! printf '%s\n' "$SENTINEL_EXEC_LINES" | grep -qE '^[[:space:]]*if[[:space:]]+\[[[:space:]]*-z[[:space:]]+"\$PROOF"[[:space:]]*\][;[:space:]]*then[[:space:]]*$'; then
  fail "sentinel does not reject missing execution proof"
fi

if ! printf '%s\n' "$SENTINEL_EXEC_LINES" | grep -qE "grep[[:space:]]+-qE[[:space:]]+'\\^\\[0-9a-f\\]\\{64\\}\\$'"; then
  fail "sentinel does not validate a 64-hex execution proof"
fi

if ! sentinel_branch_exits_one "outcome"; then
  fail "sentinel outcome failure branch must terminate with literal exit 1"
fi

if ! sentinel_branch_exits_one "missing-proof"; then
  fail "sentinel missing-proof failure branch must terminate with literal exit 1"
fi

if ! sentinel_branch_exits_one "invalid-proof"; then
  fail "sentinel invalid-proof failure branch must terminate with literal exit 1"
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

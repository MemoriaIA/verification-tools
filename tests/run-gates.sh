#!/usr/bin/env bash
# run-gates.sh — Regression gate suite for the verification-tools proof surface.
#
# Exercises BOTH advertised verifiers (Python and bash) and asserts the exact
# exit-code contract (0=valid, 1=invalid, 2=environment/usage error), not merely
# "nonzero". Also confirms the .gitignore works, the public proof-surface files
# make no forbidden claims, DISCLAIMER.md exists AND is linked, the known limitation (tail
# truncation -> valid) holds, and no vault data / keys leak into tracked files.
#
# Usage:  bash tests/run-gates.sh
# Exit:   0 iff every gate passes; 1 if any gate fails; 2 on setup failure.
#
# Portability: prefers python3, falls back to python (repo targets 3.8+, stdlib
# only). PYTHONIOENCODING=utf-8 keeps verifier output independent of the console
# code page.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

PY="$(command -v python3 || true)"
[ -z "$PY" ] && PY="$(command -v python || true)"
[ -z "$PY" ] && { echo "SETUP FAIL: no python3/python interpreter on PATH"; exit 2; }
export PYTHONIOENCODING=utf-8

PYV="memoriaia/verify/verify-hashchain.py"
SHV="verify/verify-hashchain.sh"
FIXTURE="memoriaia/fixtures/example-vault.sql"
ZERO64="0000000000000000000000000000000000000000000000000000000000000000"

WORK=".tmp-gates-$$"
rm -rf "$WORK"
mkdir "$WORK" || { echo "SETUP FAIL: could not create $WORK"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out.txt"
FAILED=0

echo "== verification-tools gate suite =="
echo "python:   $PY"
echo "verifiers: $PYV , $SHV"
echo

# ---- helpers -------------------------------------------------------------
fail() { echo "  $1: FAIL - $2"; FAILED=1; }
pass() {
  echo "  $1: PASS ${2:-}"
}

assert_exit() { # label expected actual
  if [ "$3" -eq "$2" ]; then pass "$1" "(exit $3)"; else fail "$1" "expected exit $2, got $3"; fi
}
assert_contains() { # label needle file
  if grep -qF -- "$2" "$3"; then pass "$1" "(found \"$2\")"; else fail "$1" "output missing \"$2\""; fi
}

build_db() { # target < fixture ; hard-stop on failure (no silent setup)
  sqlite3 "$1" < "$FIXTURE" >/dev/null 2>&1 || { echo "SETUP FAIL: could not load fixture into $1"; exit 2; }
}
exec_sql() { # db sql ; hard-stop on failure
  sqlite3 "$1" "$2" >/dev/null 2>&1 || { echo "SETUP FAIL: sql failed on $1"; exit 2; }
}

run_py() { "$PY" "$PYV" --vault "$1" >"$OUT" 2>&1; echo $?; }
run_sh() { bash "$SHV" "$1" >"$OUT" 2>&1; echo $?; }

# ---- fixtures ------------------------------------------------------------
VALID="$WORK/valid.sqlite";        build_db "$VALID"
TAMPER="$WORK/tamper.sqlite";      build_db "$TAMPER"
exec_sql "$TAMPER" "DROP TRIGGER IF EXISTS prevent_vault_update; UPDATE vault_entries SET hash='$ZERO64' WHERE sequence=2;"
TAIL="$WORK/tail.sqlite";          build_db "$TAIL"
exec_sql "$TAIL" "DROP TRIGGER IF EXISTS prevent_vault_delete; DELETE FROM vault_entries WHERE sequence=3;"
CORRUPT="$WORK/corrupt.bin";       printf 'this is definitely not a sqlite database' > "$CORRUPT"
NOTABLE="$WORK/notable.sqlite";    exec_sql "$NOTABLE" "CREATE TABLE other(x);"
PIPE_PAYLOAD="$WORK/pipe-payload.sqlite"
CONTROL_PAYLOAD="$WORK/control-payload.sqlite"
GAP="$WORK/gap.sqlite"
REWRITE="$WORK/rewrite.sqlite"
if ! "$PY" - "$PYV" "$PIPE_PAYLOAD" "$CONTROL_PAYLOAD" "$GAP" "$REWRITE" <<'PY'
import importlib.util
import sqlite3
import sys

verifier_path, pipe_db, control_db, gap_db, rewrite_db = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("verify_hashchain", verifier_path)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

schema = """
CREATE TABLE vault_entries (
  id TEXT NOT NULL PRIMARY KEY,
  sequence INTEGER NOT NULL UNIQUE CHECK (sequence >= 1),
  timestamp TEXT NOT NULL,
  authority_source TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  payload TEXT NOT NULL,
  prev_hash TEXT NOT NULL CHECK (length(prev_hash) = 64 AND prev_hash NOT GLOB '*[^0-9a-f]*'),
  hash TEXT NOT NULL CHECK (length(hash) = 64 AND hash NOT GLOB '*[^0-9a-f]*')
);
"""

def make_row(seq, payload, prev_hash):
    row = {
        "id": f"row-{seq}",
        "sequence": seq,
        "timestamp": f"2026-07-03T00:00:0{seq}Z",
        "authority_source": "system",
        "entity_type": "memory.created",
        "payload": payload,
        "prev_hash": prev_hash,
    }
    row["hash"] = verifier.compute_record_hash(row)
    return row

def write_db(path, rows):
    conn = sqlite3.connect(path)
    conn.executescript(schema)
    conn.executemany(
        "INSERT INTO vault_entries (id, sequence, timestamp, authority_source, entity_type, payload, prev_hash, hash) VALUES (:id, :sequence, :timestamp, :authority_source, :entity_type, :payload, :prev_hash, :hash)",
        rows,
    )
    conn.commit()
    conn.close()

def chain(payloads, sequence_values=None):
    rows = []
    prev = "0" * 64
    if sequence_values is None:
        sequence_values = list(range(1, len(payloads) + 1))
    for seq, payload in zip(sequence_values, payloads):
        row = make_row(seq, payload, prev)
        rows.append(row)
        prev = row["hash"]
    return rows

write_db(pipe_db, chain(["cipher|text"]))
write_db(control_db, chain(["a\bb"]))
write_db(gap_db, chain(["kept-first", "kept-third"], [1, 3]))
write_db(rewrite_db, chain(["rewritten-first", "rewritten-second"]))
PY
then
  echo "SETUP FAIL: could not build edge-case fixtures"
  exit 2
fi

# ---- G-1/G-2: syntax -----------------------------------------------------
echo "[syntax]"
"$PY" -m py_compile "$PYV" 2>/dev/null && pass "G-1 python syntax" || fail "G-1 python syntax" "py_compile failed"
bash -n "$SHV" 2>/dev/null && pass "G-2 bash syntax" || fail "G-2 bash syntax" "bash -n failed"

# ---- G-3: fixture loads --------------------------------------------------
echo "[fixture]"
sqlite3 "$WORK/g3.sqlite" < "$FIXTURE" >/dev/null 2>&1 && pass "G-3 fixture loads" || fail "G-3 fixture loads" "load failed"

# ---- Python verifier contract (G-4..G-8) ---------------------------------
echo "[python verifier]"
rc=$(run_py "$VALID");   assert_exit "G-4 py valid exit0" 0 "$rc"; assert_contains "G-4 py valid says VALID" "Chain VALID" "$OUT"; assert_contains "G-4 py valid count" "3 record" "$OUT"
rc=$(run_py "$TAMPER");  assert_exit "G-5 py tamper exit1" 1 "$rc"; assert_contains "G-5 py tamper says INVALID" "Chain INVALID" "$OUT"
rc=$(run_py "$TAIL");    assert_exit "G-6 py tail exit0" 0 "$rc";   assert_contains "G-6 py tail count (known limitation)" "2 record" "$OUT"
rc=$(run_py "$CORRUPT"); assert_exit "G-7 py corrupt exit2" 2 "$rc"
rc=$(run_py "$NOTABLE"); assert_exit "G-8 py missing-table exit2" 2 "$rc"
rc=$(run_py "$PIPE_PAYLOAD"); assert_exit "G-8a py pipe payload exit0" 0 "$rc"
rc=$(run_py "$CONTROL_PAYLOAD"); assert_exit "G-8b py control-char payload exit0" 0 "$rc"
rc=$(run_py "$GAP"); assert_exit "G-8c py sequence gap exit1" 1 "$rc"; assert_contains "G-8c py sequence gap diagnostic" "SEQUENCE GAP" "$OUT"
rc=$(run_py "$REWRITE"); assert_exit "G-8d py self-consistent rewrite limitation exit0" 0 "$rc"; assert_contains "G-8d py rewrite count" "2 record" "$OUT"

# ---- Bash verifier contract (G-9..G-12) ----------------------------------
echo "[bash verifier]"
rc=$(run_sh "$VALID");   assert_exit "G-9 sh valid exit0" 0 "$rc"; assert_contains "G-9 sh valid says VALID" "Chain VALID" "$OUT"; assert_contains "G-9 sh valid count" "3 record" "$OUT"
rc=$(run_sh "$TAMPER");  assert_exit "G-10 sh tamper exit1" 1 "$rc"; assert_contains "G-10 sh tamper says INVALID" "Chain INVALID" "$OUT"
rc=$(run_sh "$TAIL");    assert_exit "G-11 sh tail exit0" 0 "$rc";   assert_contains "G-11 sh tail count (known limitation)" "2 record" "$OUT"
rc=$(run_sh "$CORRUPT"); assert_exit "G-12a sh corrupt exit2" 2 "$rc"
rc=$(run_sh "$NOTABLE"); assert_exit "G-12b sh missing-table exit2" 2 "$rc"
rc=$(run_sh "$PIPE_PAYLOAD"); assert_exit "G-12c sh pipe payload exit0" 0 "$rc"
rc=$(run_sh "$CONTROL_PAYLOAD"); assert_exit "G-12d sh control-char payload exit0" 0 "$rc"
rc=$(run_sh "$GAP"); assert_exit "G-12e sh sequence gap exit1" 1 "$rc"; assert_contains "G-12e sh sequence gap diagnostic" "SEQUENCE GAP" "$OUT"
rc=$(run_sh "$REWRITE"); assert_exit "G-12f sh self-consistent rewrite limitation exit0" 0 "$rc"; assert_contains "G-12f sh rewrite count" "2 record" "$OUT"

# ---- G-13: both verifiers agree on the valid fixture ---------------------
echo "[cross-check]"
prc=$(run_py "$VALID"); src=$(run_sh "$VALID")
if [ "$prc" -eq 0 ] && [ "$src" -eq 0 ]; then pass "G-13 both verifiers accept valid fixture"; else fail "G-13 verifier agreement" "python exit $prc, bash exit $src"; fi

mkdir -p "$WORK/bin"
cat > "$WORK/bin/python3" <<PY3
#!/usr/bin/env bash
exec "$PY" "\$@"
PY3
chmod +x "$WORK/bin/python3"
PATH="$WORK/bin:/usr/bin:/bin" bash "$SHV" "$VALID" >"$OUT" 2>&1
assert_exit "G-13b bash resolves python3-only PATH" 0 "$?"

# ---- G-14: .gitignore excludes .claude/ ----------------------------------
echo "[repo hygiene]"
git check-ignore -v .claude/test >/dev/null 2>&1 && pass "G-14 .gitignore .claude/" || fail "G-14 .gitignore .claude/" ".claude/ not ignored"

# ---- G-15: no forbidden claim phrases in public proof surface ------------
FORBIDDEN='certif(y|ied|ication|ications?)|compliant|compliance|court[- ]admissible|legally binding|enterprise[- ]ready|production[- ]ready|public[- ]ready|audit[- ]passed|prove(s|d)?[[:space:]-]+(the[[:space:]-]+)?truth|tamper[[:space:]-]*proof|prove(s|d)?[[:space:]-]+no[[:space:]-]+deletion|prove(s|d)?[[:space:]-]+(full[[:space:]-]+|vault[[:space:]-]+)?completeness|any[[:space:]-]+alteration|detect(s|ed|ing)?[[:space:]-]+(any[[:space:]-]+)?tamper(ing|ed)?|interior[[:space:]-]+deletion|append[- ]only[[:space:]-]+proof|historical[[:space:]-]+record.*detectable|CISO|NASA'
G15_TARGETS=(README.md DISCLAIMER.md SECURITY.md memoriaia verify)
G15_MISSING=0
for target in "${G15_TARGETS[@]}"; do
  if ! git ls-files --error-unmatch "$target" >/dev/null 2>&1 && ! git ls-files "$target" | grep -q .; then
    fail "G-15 scan target exists" "$target is missing from tracked public proof surface"
    G15_MISSING=1
  fi
done
if [ "$G15_MISSING" -eq 0 ]; then
  G15_OUT="$WORK/g15-claims.txt"
  git grep -nI -i -E "$FORBIDDEN" -- "${G15_TARGETS[@]}" >"$G15_OUT" 2>"$WORK/g15-errors.txt"
  G15_STATUS="$?"
  if [ "$G15_STATUS" -eq 0 ]; then
    fail "G-15 forbidden claim" "$(tr '\n' ';' <"$G15_OUT")"
  elif [ "$G15_STATUS" -eq 1 ]; then
    pass "G-15 no forbidden claims"
  else
    fail "G-15 scan completed" "$(tr '\n' ';' <"$WORK/g15-errors.txt")"
  fi
fi

# ---- G-16: DISCLAIMER.md exists AND is discoverable ----------------------
if [ -f DISCLAIMER.md ]; then
  if grep -iE "DISCLAIMER\.md" README.md >/dev/null 2>&1; then pass "G-16 DISCLAIMER exists & linked"; else fail "G-16 DISCLAIMER link" "DISCLAIMER.md exists but is not linked from README.md"; fi
else
  fail "G-16 DISCLAIMER exists" "DISCLAIMER.md missing"
fi

# ---- G-17: no phantom requirements.txt -----------------------------------
[ ! -f memoriaia/verify/requirements.txt ] && pass "G-17 no phantom requirements.txt" || fail "G-17 phantom requirements.txt" "unexpected requirements.txt present"

# ---- G-18: no leakage — allowlist + sensitive-pattern denylist (hard fail)
ALLOWED='^(README\.md|SECURITY\.md|DISCLAIMER\.md|LICENSE|\.gitignore|\.gitattributes|\.github/workflows/ci\.yml|memoriaia/schema/[A-Za-z0-9._-]+\.sql|memoriaia/fixtures/[A-Za-z0-9._-]+\.sql|memoriaia/verify/verify-hashchain\.py|verify/verify-hashchain\.sh|tests/run-gates\.sh|tests/g19-v2-structural-check\.sh|tests/fixtures/g19-v2/(baseline-good|baseline-unrelated-github-output|missing-proof-mutant|mutant-comment-only-sentinel|mutant-continue-on-error|mutant-direct-github-output-proof-write|mutant-folded-subshell-true-paren|mutant-forged-indirect-output-unreachable|mutant-forged-proof-output|mutant-gates-extraction-service-name-collision|mutant-gate-steps-hidden-in-shell-string|mutant-gates-needs-skipped-blocker|mutant-job-default-shell-alias-or-true|mutant-job-default-shell-flow-map-or-true|mutant-job-default-shell-merge-key-or-true|mutant-job-default-shell-or-true|mutant-job-default-shell-run-alias-or-true|mutant-if-false-run|mutant-job-continue-on-error|mutant-job-if-false|mutant-job-if-post-steps-expression|mutant-job-quoted-continue-on-error|mutant-job-quoted-if-false|mutant-job-yaml-alias-continue-on-error|mutant-job-yaml-alias-if-false|mutant-jobs-key-in-block-scalar|mutant-missing-sentinel|mutant-or-true-paren|mutant-or-true|mutant-prestep-bashenv-forged-output|mutant-prestep-github-path-python-poison|mutant-semicolon-true|mutant-sentinel-case-inert-guard|mutant-sentinel-echo-only-failure|mutant-sentinel-exit-in-else-branch|mutant-sentinel-false-and-brace-group|mutant-sentinel-heredoc-inert|mutant-sentinel-heredoc-numeric-delimiter|mutant-sentinel-exit-zero-expression|mutant-sentinel-fake-outcome-comparison|mutant-sentinel-invalid-proof-echo-branch|mutant-sentinel-invalid-proof-elif-exit|mutant-sentinel-invalid-proof-nested-inert-exit|mutant-sentinel-missing-proof-elif-exit|mutant-sentinel-missing-proof-nested-inert-exit|mutant-sentinel-outcome-elif-exit|mutant-sentinel-outcome-nested-inert-exit|mutant-sentinel-proof-array-overwrite|mutant-sentinel-proof-declare-overwrite|mutant-sentinel-proof-nameref-overwrite|mutant-sentinel-proof-parameter-default|mutant-sentinel-proof-overwrite-constant|mutant-sentinel-quoted-continue-on-error|mutant-sentinel-skipped-or-group|mutant-sentinel-split-line-function|mutant-sentinel-step-if-skipped|mutant-sentinel-trap-exit-zero|mutant-sentinel-uncalled-function|mutant-sentinel-unreachable-invalid-proof-guard|mutant-sentinel-unreachable-missing-proof-guard|mutant-sentinel-while-false-inert-guard|mutant-step-if-expression-run|mutant-step-quoted-continue-on-error|mutant-step-quoted-if-run|mutant-workflow-default-shell-alias-or-true|mutant-workflow-default-shell-flow-map-or-true|mutant-workflow-default-shell-merge-key-or-true|mutant-workflow-default-shell-or-true|mutant-workflow-default-shell-run-alias-or-true|skipped-run_gates-mutant)\.yml)$'
ALLOWED="${ALLOWED/mutant-prestep-bashenv-forged-output|mutant-prestep-github-path-python-poison/mutant-job-env-bashenv-obfuscated-output|mutant-prestep-bashenv-forged-output|mutant-prestep-github-path-chocolatey-poison|mutant-prestep-github-path-python-poison|mutant-prestep-heredoc-github-output-proof-write|mutant-prestep-indirect-github-output-proof-write}"
ALLOWED="${ALLOWED/mutant-job-env-bashenv-obfuscated-output/mutant-gates-merge-key-bypass|mutant-job-env-bashenv-obfuscated-output}"
ALLOWED="${ALLOWED/mutant-prestep-indirect-github-output-proof-write/mutant-prestep-computed-github-output-proof-write|mutant-prestep-indirect-github-output-proof-write|mutant-prestep-obfuscated-env-poison}"
ALLOWED="${ALLOWED/mutant-prestep-obfuscated-env-poison/mutant-prestep-obfuscated-env-poison|mutant-prestep-split-github-env-bashenv|mutant-prestep-split-github-output-proof|mutant-prestep-split-github-path}"
ALLOWED="${ALLOWED/mutant-step-if-expression-run/mutant-step-if-expression-run|mutant-step-uses-upload-artifact}"
ALLOWED="${ALLOWED/baseline-unrelated-github-output/baseline-unrelated-github-output|baseline-windows-github-path-single-quote}"
ALLOWED="${ALLOWED/mutant-step-if-expression-run/mutant-step-if-expression-run|mutant-step-merge-key-continue-on-error}"
ALLOWED="${ALLOWED/baseline-windows-github-path-single-quote/baseline-anonymous-checkout|baseline-quoted-env-key|baseline-windows-github-path-single-quote}"
ALLOWED="${ALLOWED/mutant-direct-github-output-proof-write/mutant-anonymous-run-bashenv-github-env|mutant-anonymous-uses-upload-artifact|mutant-direct-github-output-proof-write}"
ALLOWED="${ALLOWED/mutant-job-env-bashenv-obfuscated-output/mutant-escaped-bashenv-key|mutant-escaped-github-env-key|mutant-escaped-github-path-key|mutant-escaped-pythonpath-key|mutant-job-env-bashenv-obfuscated-output}"
ALLOWED="${ALLOWED/mutant-job-env-path-poison/mutant-job-env-path-poison}"
ALLOWED="${ALLOWED/mutant-prestep-eval-github-env-bashenv/mutant-prestep-eval-github-env-bashenv}"
ALLOWED="${ALLOWED/mutant-prestep-eval-github-path-poison/mutant-prestep-eval-github-path-poison}"
ALLOWED="${ALLOWED/mutant-prestep-eval-github-output-proof/mutant-prestep-eval-github-output-proof}"
ALLOWED="${ALLOWED/mutant-sentinel-proof-builtin-nameref-overwrite/mutant-sentinel-proof-builtin-nameref-overwrite}"
ALLOWED="${ALLOWED/mutant-sentinel-proof-command-nameref-overwrite/mutant-sentinel-proof-command-nameref-overwrite}"
ALLOWED="${ALLOWED/mutant-sentinel-proof-chained-builtin-nameref-overwrite/mutant-sentinel-proof-chained-builtin-nameref-overwrite}"
ALLOWED="${ALLOWED/mutant-step-env-path-poison/mutant-step-env-path-poison}"
ALLOWED="${ALLOWED/mutant-workflow-env-path-poison/mutant-workflow-env-path-poison}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|mutant-job-env-bash-func-bash-forges-proof|mutant-job-env-path-poison|mutant-prestep-eval-github-env-bashenv|mutant-prestep-eval-github-path-poison|mutant-prestep-eval-github-output-proof|mutant-sentinel-proof-builtin-nameref-overwrite|mutant-sentinel-proof-command-nameref-overwrite|mutant-sentinel-proof-chained-builtin-nameref-overwrite|mutant-step-env-path-poison|mutant-workflow-env-path-poison}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|baseline-anonymous-env-first|baseline-escaped-x-key|baseline-inline-anonymous-run|mutant-anonymous-env-first-bashenv|mutant-escaped-x-bashenv-key|mutant-escaped-x-github-env-key|mutant-escaped-x-github-path-key|mutant-escaped-x-pythonpath-key|mutant-flow-run-github-env-bashenv|mutant-flow-uses-upload-artifact|mutant-inline-anonymous-run-github-env-bashenv|mutant-inline-anonymous-run-github-output-proof|mutant-prestep-if-eval-github-env-bashenv|mutant-prestep-if-eval-github-output-proof|mutant-prestep-if-eval-github-path-poison|mutant-prestep-while-eval-github-env-bashenv|mutant-sentinel-proof-backslash-builtin-nameref-overwrite|mutant-sentinel-proof-backslash-command-nameref-overwrite|mutant-sentinel-proof-backslash-declare-nameref-overwrite|mutant-sentinel-proof-chained-backslash-declare-nameref-overwrite}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|baseline-inline-run-decoded-safe|baseline-inline-run-quoted-continuation-safe|mutant-anchored-flow-run-github-env-bashenv|mutant-anchored-flow-uses-upload-artifact|mutant-inline-run-escaped-env-github-env|mutant-inline-run-escaped-github-output-proof|mutant-inline-run-quoted-continuation-github-env|mutant-inline-run-quoted-continuation-github-output-proof|mutant-prestep-chained-escaped-eval-github-output-proof|mutant-prestep-if-escaped-eval-github-env-bashenv|mutant-prestep-while-escaped-eval-github-env-bashenv|mutant-sentinel-proof-builtin-command-nameref-overwrite|mutant-sentinel-proof-builtin-escaped-option-nameref-overwrite|mutant-sentinel-proof-chained-plain-wrapper-nameref-overwrite|mutant-sentinel-proof-chained-wrapper-nameref-overwrite|mutant-sentinel-proof-escaped-declare-option-nameref-overwrite|mutant-sentinel-proof-escaped-option-nameref-overwrite}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|mutant-alias-step-run-bash-c-github-env|mutant-anchored-block-run-bash-c-github-env|mutant-inline-run-scalar-alias-bash-c-github-env|mutant-inline-run-scalar-anchor-bash-c-github-env|mutant-prestep-ansi-quoted-eval-base64-github-env|mutant-prestep-bash-c-base64-github-env|mutant-prestep-dynamic-eval-base64-github-env|mutant-prestep-python-computed-github-env-bashenv|mutant-prestep-python-computed-github-path|mutant-prestep-quoted-eval-base64-github-env|mutant-sentinel-proof-variable-option-nameref-overwrite}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|baseline-run-folded2-safe|baseline-run-pipe2-safe|mutant-prestep-run-folded2-line2-github-env|mutant-prestep-run-folded9-chomp-github-output-proof|mutant-prestep-run-folded9-line2-github-output-proof|mutant-prestep-run-pipe2-chomp-github-env|mutant-prestep-run-pipe2-line2-bashenv|mutant-prestep-run-pipe2-line2-github-env|mutant-prestep-run-pipe-chomp2-github-env|mutant-prestep-run-pipe9-line2-github-output-proof}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|mutant-prestep-list-item-merge-poison-run|mutant-prestep-list-item-merge-poison-env|mutant-prestep-list-item-merge-poison-uses|mutant-prestep-block-ansi-u005f-env|mutant-prestep-block-ansi-x5f-env|mutant-prestep-block-ansi-u005f-output-proof|mutant-prestep-block-ansi-u005f-path|mutant-sentinel-declare-hex-n-nameref|mutant-sentinel-local-hex-n-nameref|mutant-sentinel-typeset-hex-n-nameref|mutant-sentinel-declare-ansi-n-nameref|mutant-prestep-usrbin-bash-c-github-env|mutant-prestep-env-i-bash-c-github-output-proof|mutant-prestep-sh-c-github-env|mutant-prestep-tab-indented-block-github-env}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|mutant-inline-anonymous-run-pipe2-chomp-github-env|mutant-inline-run-plain-continuation-github-env-bashenv|mutant-inline-run-plain-continuation-github-output-proof|mutant-inline-run-single-quoted-continuation-github-env-bashenv|mutant-inline-run-single-quoted-continuation-github-output-proof}"
TRACKED_FILES="$WORK/tracked-files.txt"
if ! git ls-files >"$TRACKED_FILES"; then
  fail "G-18 tracked file scan completed" "git ls-files failed"
fi
UNEXPECTED_STATUS=0
UNEXPECTED="$(grep -vE "$ALLOWED" "$TRACKED_FILES")" || UNEXPECTED_STATUS="$?"
if [ "$UNEXPECTED_STATUS" -eq 1 ]; then
  UNEXPECTED=""
elif [ "$UNEXPECTED_STATUS" -ne 0 ]; then
  fail "G-18 tracked allowlist scan completed" "grep status $UNEXPECTED_STATUS"
  UNEXPECTED=""
fi
SENSITIVE_STATUS=0
SENSITIVE="$(grep -iE '\.(sqlite|sqlite3|db|pem|key|env|p12|pfx|crt)$|(^|/)id_(rsa|ed25519)' "$TRACKED_FILES")" || SENSITIVE_STATUS="$?"
if [ "$SENSITIVE_STATUS" -eq 1 ]; then
  SENSITIVE=""
elif [ "$SENSITIVE_STATUS" -ne 0 ]; then
  fail "G-18 sensitive pattern scan completed" "grep status $SENSITIVE_STATUS"
  SENSITIVE=""
fi
G18_PROBE_STATUS=0
grep -E '[' "$TRACKED_FILES" >"$WORK/g18-grep-probe.txt" 2>"$WORK/g18-grep-probe.err" || G18_PROBE_STATUS="$?"
if [ "$G18_PROBE_STATUS" -gt 1 ]; then
  pass "G-18 grep errors are not normalized" "(grep status $G18_PROBE_STATUS)"
else
  fail "G-18 grep error probe" "expected grep syntax failure, got status $G18_PROBE_STATUS"
fi
if [ -z "$UNEXPECTED" ] && [ -z "$SENSITIVE" ]; then
  pass "G-18 no leakage (tracked file set is the known allowlist)"
else
  [ -n "$UNEXPECTED" ] && fail "G-18 unexpected tracked file(s)" "$(printf '%s' "$UNEXPECTED" | tr '\n' ';')"
  [ -n "$SENSITIVE" ]  && fail "G-18 sensitive tracked file(s)"  "$(printf '%s' "$SENSITIVE"  | tr '\n' ';')"
fi

# ---- G-19: CI must invoke run-gates.sh 1:1 (anti-theater) ----------------
echo "[ci anti-theater]"
bash tests/g19-v2-structural-check.sh .github/workflows/ci.yml || fail "G-19 v2 structural check" "ci.yml contains structural anomalies"
if [ "$FAILED" -eq 0 ]; then pass "G-19 v2 structural check"; fi

G19_FIXTURE_DIR="tests/fixtures/g19-v2"
G19_BASELINE_FIXTURES="
baseline-good.yml
baseline-anonymous-checkout.yml
baseline-anonymous-env-first.yml
baseline-escaped-x-key.yml
baseline-inline-anonymous-run.yml
baseline-inline-run-decoded-safe.yml
baseline-inline-run-quoted-continuation-safe.yml
baseline-quoted-env-key.yml
baseline-run-folded2-safe.yml
baseline-run-pipe2-safe.yml
baseline-unrelated-github-output.yml
baseline-windows-github-path-single-quote.yml
"
G19_MUTANT_FIXTURES="
missing-proof-mutant.yml
mutant-alias-step-run-bash-c-github-env.yml
mutant-anchored-block-run-bash-c-github-env.yml
mutant-anchored-flow-run-github-env-bashenv.yml
mutant-anchored-flow-uses-upload-artifact.yml
mutant-anonymous-run-bashenv-github-env.yml
mutant-anonymous-uses-upload-artifact.yml
mutant-anonymous-env-first-bashenv.yml
mutant-comment-only-sentinel.yml
mutant-continue-on-error.yml
mutant-direct-github-output-proof-write.yml
mutant-escaped-x-bashenv-key.yml
mutant-escaped-x-github-env-key.yml
mutant-escaped-x-github-path-key.yml
mutant-escaped-x-pythonpath-key.yml
mutant-escaped-bashenv-key.yml
mutant-escaped-github-env-key.yml
mutant-escaped-github-path-key.yml
mutant-escaped-pythonpath-key.yml
mutant-flow-run-github-env-bashenv.yml
mutant-flow-uses-upload-artifact.yml
mutant-folded-subshell-true-paren.yml
mutant-forged-indirect-output-unreachable.yml
mutant-forged-proof-output.yml
mutant-gates-extraction-service-name-collision.yml
mutant-gates-merge-key-bypass.yml
mutant-gate-steps-hidden-in-shell-string.yml
mutant-gates-needs-skipped-blocker.yml
mutant-job-env-bash-func-bash-forges-proof.yml
mutant-job-env-bashenv-obfuscated-output.yml
mutant-job-env-path-poison.yml
mutant-prestep-bashenv-forged-output.yml
mutant-prestep-ansi-quoted-eval-base64-github-env.yml
mutant-prestep-block-ansi-u005f-env.yml
mutant-prestep-block-ansi-u005f-output-proof.yml
mutant-prestep-block-ansi-u005f-path.yml
mutant-prestep-block-ansi-x5f-env.yml
mutant-prestep-bash-c-base64-github-env.yml
mutant-prestep-dynamic-eval-base64-github-env.yml
mutant-prestep-computed-github-output-proof-write.yml
mutant-prestep-eval-github-env-bashenv.yml
mutant-prestep-eval-github-output-proof.yml
mutant-prestep-eval-github-path-poison.yml
mutant-prestep-if-eval-github-env-bashenv.yml
mutant-prestep-if-eval-github-output-proof.yml
mutant-prestep-if-eval-github-path-poison.yml
mutant-prestep-chained-escaped-eval-github-output-proof.yml
mutant-prestep-if-escaped-eval-github-env-bashenv.yml
mutant-prestep-quoted-eval-base64-github-env.yml
mutant-prestep-run-folded2-line2-github-env.yml
mutant-prestep-run-folded9-chomp-github-output-proof.yml
mutant-prestep-run-folded9-line2-github-output-proof.yml
mutant-prestep-run-pipe2-chomp-github-env.yml
mutant-prestep-run-pipe2-line2-bashenv.yml
mutant-prestep-run-pipe2-line2-github-env.yml
mutant-prestep-run-pipe-chomp2-github-env.yml
mutant-prestep-run-pipe9-line2-github-output-proof.yml
mutant-inline-anonymous-run-pipe2-chomp-github-env.yml
mutant-inline-run-plain-continuation-github-env-bashenv.yml
mutant-inline-run-plain-continuation-github-output-proof.yml
mutant-inline-run-single-quoted-continuation-github-env-bashenv.yml
mutant-inline-run-single-quoted-continuation-github-output-proof.yml
mutant-prestep-while-escaped-eval-github-env-bashenv.yml
mutant-prestep-while-eval-github-env-bashenv.yml
mutant-prestep-github-path-chocolatey-poison.yml
mutant-prestep-github-path-python-poison.yml
mutant-prestep-heredoc-github-output-proof-write.yml
mutant-prestep-indirect-github-output-proof-write.yml
mutant-prestep-list-item-merge-poison-env.yml
mutant-prestep-list-item-merge-poison-run.yml
mutant-prestep-list-item-merge-poison-uses.yml
mutant-prestep-obfuscated-env-poison.yml
mutant-prestep-python-computed-github-env-bashenv.yml
mutant-prestep-python-computed-github-path.yml
mutant-prestep-split-github-env-bashenv.yml
mutant-prestep-split-github-output-proof.yml
mutant-prestep-split-github-path.yml
mutant-prestep-env-i-bash-c-github-output-proof.yml
mutant-prestep-sh-c-github-env.yml
mutant-prestep-tab-indented-block-github-env.yml
mutant-prestep-usrbin-bash-c-github-env.yml
mutant-job-default-shell-alias-or-true.yml
mutant-job-default-shell-flow-map-or-true.yml
mutant-job-default-shell-merge-key-or-true.yml
mutant-job-default-shell-or-true.yml
mutant-job-default-shell-run-alias-or-true.yml
mutant-if-false-run.yml
mutant-inline-run-escaped-env-github-env.yml
mutant-inline-run-escaped-github-output-proof.yml
mutant-inline-run-quoted-continuation-github-env.yml
mutant-inline-run-quoted-continuation-github-output-proof.yml
mutant-inline-run-scalar-alias-bash-c-github-env.yml
mutant-inline-run-scalar-anchor-bash-c-github-env.yml
mutant-job-continue-on-error.yml
mutant-job-if-false.yml
mutant-job-if-post-steps-expression.yml
mutant-job-quoted-continue-on-error.yml
mutant-job-quoted-if-false.yml
mutant-job-yaml-alias-continue-on-error.yml
mutant-job-yaml-alias-if-false.yml
mutant-jobs-key-in-block-scalar.yml
mutant-missing-sentinel.yml
mutant-or-true-paren.yml
mutant-or-true.yml
mutant-semicolon-true.yml
mutant-sentinel-case-inert-guard.yml
mutant-sentinel-declare-ansi-n-nameref.yml
mutant-sentinel-declare-hex-n-nameref.yml
mutant-sentinel-echo-only-failure.yml
mutant-sentinel-exit-in-else-branch.yml
mutant-sentinel-false-and-brace-group.yml
mutant-sentinel-heredoc-inert.yml
mutant-sentinel-heredoc-numeric-delimiter.yml
mutant-sentinel-exit-zero-expression.yml
mutant-sentinel-fake-outcome-comparison.yml
mutant-sentinel-invalid-proof-echo-branch.yml
mutant-sentinel-invalid-proof-elif-exit.yml
mutant-sentinel-invalid-proof-nested-inert-exit.yml
mutant-sentinel-local-hex-n-nameref.yml
mutant-sentinel-missing-proof-elif-exit.yml
mutant-sentinel-missing-proof-nested-inert-exit.yml
mutant-sentinel-outcome-elif-exit.yml
mutant-sentinel-outcome-nested-inert-exit.yml
mutant-sentinel-proof-array-overwrite.yml
mutant-sentinel-proof-backslash-builtin-nameref-overwrite.yml
mutant-sentinel-proof-backslash-command-nameref-overwrite.yml
mutant-sentinel-proof-backslash-declare-nameref-overwrite.yml
mutant-sentinel-proof-builtin-command-nameref-overwrite.yml
mutant-sentinel-proof-builtin-escaped-option-nameref-overwrite.yml
mutant-sentinel-proof-builtin-nameref-overwrite.yml
mutant-sentinel-proof-chained-backslash-declare-nameref-overwrite.yml
mutant-sentinel-proof-chained-plain-wrapper-nameref-overwrite.yml
mutant-sentinel-proof-chained-wrapper-nameref-overwrite.yml
mutant-sentinel-proof-chained-builtin-nameref-overwrite.yml
mutant-sentinel-proof-command-nameref-overwrite.yml
mutant-sentinel-proof-declare-overwrite.yml
mutant-sentinel-proof-escaped-declare-option-nameref-overwrite.yml
mutant-sentinel-proof-escaped-option-nameref-overwrite.yml
mutant-sentinel-proof-nameref-overwrite.yml
mutant-sentinel-proof-parameter-default.yml
mutant-sentinel-proof-overwrite-constant.yml
mutant-sentinel-proof-variable-option-nameref-overwrite.yml
mutant-sentinel-quoted-continue-on-error.yml
mutant-sentinel-skipped-or-group.yml
mutant-sentinel-split-line-function.yml
mutant-sentinel-step-if-skipped.yml
mutant-sentinel-trap-exit-zero.yml
mutant-sentinel-typeset-hex-n-nameref.yml
mutant-sentinel-uncalled-function.yml
mutant-sentinel-unreachable-invalid-proof-guard.yml
mutant-sentinel-unreachable-missing-proof-guard.yml
mutant-sentinel-while-false-inert-guard.yml
mutant-step-if-expression-run.yml
mutant-inline-anonymous-run-github-env-bashenv.yml
mutant-inline-anonymous-run-github-output-proof.yml
mutant-step-merge-key-continue-on-error.yml
mutant-step-env-path-poison.yml
mutant-step-quoted-continue-on-error.yml
mutant-step-quoted-if-run.yml
mutant-step-uses-upload-artifact.yml
mutant-workflow-env-path-poison.yml
mutant-workflow-default-shell-alias-or-true.yml
mutant-workflow-default-shell-flow-map-or-true.yml
mutant-workflow-default-shell-merge-key-or-true.yml
mutant-workflow-default-shell-or-true.yml
mutant-workflow-default-shell-run-alias-or-true.yml
skipped-run_gates-mutant.yml
"
G19_EXPECTED_FIXTURES="$G19_BASELINE_FIXTURES $G19_MUTANT_FIXTURES"

G19_FIXTURE_MISSING=0
for fixture in $G19_EXPECTED_FIXTURES; do
  fixture_path="$G19_FIXTURE_DIR/$fixture"
  if [ ! -f "$fixture_path" ]; then
    fail "G-19 v2 fixture exists" "$fixture missing"
    G19_FIXTURE_MISSING=1
  elif ! git ls-files --error-unmatch "$fixture_path" >/dev/null 2>&1; then
    fail "G-19 v2 fixture tracked" "$fixture is not tracked in git"
    G19_FIXTURE_MISSING=1
  else
    fixture_sha="$(sha256sum "$fixture_path" | awk '{print $1}')"
  fi
done

if [ -d "$G19_FIXTURE_DIR" ]; then
  for fixture_path in "$G19_FIXTURE_DIR"/*.yml; do
    [ -e "$fixture_path" ] || continue
    fixture_name="$(basename "$fixture_path")"
    G19_FIXTURE_EXPECTED=0
    for expected_fixture in $G19_EXPECTED_FIXTURES; do
      [ "$fixture_name" = "$expected_fixture" ] && G19_FIXTURE_EXPECTED=1
    done
    [ "$G19_FIXTURE_EXPECTED" -eq 1 ] || fail "G-19 v2 fixture inventory" "unexpected fixture $fixture_name"
  done
else
  fail "G-19 v2 fixture directory exists" "$G19_FIXTURE_DIR missing"
  G19_FIXTURE_MISSING=1
fi

if [ "$G19_FIXTURE_MISSING" -eq 0 ]; then
  for fixture in $G19_BASELINE_FIXTURES; do
    if bash tests/g19-v2-structural-check.sh "$G19_FIXTURE_DIR/$fixture" >"$OUT" 2>&1; then
      pass "G-19 v2 baseline fixture passes $fixture"
    else
      fail "G-19 v2 baseline fixture passes $fixture" "$(tr '\n' ';' <"$OUT")"
    fi
  done

  for fixture in $G19_MUTANT_FIXTURES; do
    if bash tests/g19-v2-structural-check.sh "$G19_FIXTURE_DIR/$fixture" >"$OUT" 2>&1; then
      fail "G-19 v2 rejects $fixture" "mutant unexpectedly passed"
    else
      pass "G-19 v2 rejects $fixture"
    fi
  done
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "ALL GATES PASS"
  HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
  tracked_blob_sha256() {
    git cat-file blob "HEAD:$1" | sha256sum | awk '{print $1}'
  }
  fixture_manifest_sha256() {
    git ls-files 'tests/fixtures/g19-v2/*.yml' |
      while IFS= read -r fixture; do
        printf '%s  %s\n' "$(tracked_blob_sha256 "$fixture")" "$fixture"
      done |
      sha256sum |
      awk '{print $1}'
  }
  RUN_GATES_SHA="$(tracked_blob_sha256 "tests/run-gates.sh")"
  STRUCTURAL_CHECK_SHA="$(tracked_blob_sha256 "tests/g19-v2-structural-check.sh")"
  G19_FIXTURE_MANIFEST_SHA="$(fixture_manifest_sha256)"
  PROOF_PR_HEAD_SHA="${VT_G19_PR_HEAD_SHA:-$HEAD_SHA}"
  PROOF_PR_BASE_SHA="${VT_G19_PR_BASE_SHA:-$HEAD_SHA}"
  PROOF_CHECKOUT_SHA="${VT_G19_CHECKOUT_SHA:-$HEAD_SHA}"
  for proof_sha in "$PROOF_PR_HEAD_SHA" "$PROOF_PR_BASE_SHA" "$PROOF_CHECKOUT_SHA"; do
    if ! printf '%s\n' "$proof_sha" | grep -qE '^[0-9a-f]{40}$'; then
      echo "SETUP FAIL: invalid VT_G19 proof SHA input ($proof_sha)"
      exit 2
    fi
  done
  VT_G19_EXEC_PROOF="$(
    printf 'VT_G19_EXECUTED:v2\nPR_HEAD:%s\nPR_BASE:%s\nCHECKOUT:%s\nRUN_GATES:%s\nSTRUCTURAL:%s\nFIXTURES:%s\n' \
      "$PROOF_PR_HEAD_SHA" "$PROOF_PR_BASE_SHA" "$PROOF_CHECKOUT_SHA" \
      "$RUN_GATES_SHA" "$STRUCTURAL_CHECK_SHA" "$G19_FIXTURE_MANIFEST_SHA" |
      sha256sum |
      awk '{print $1}'
  )"
  echo "VT_G19_EXEC_PROOF=$VT_G19_EXEC_PROOF"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "vt_g19_exec_proof=$VT_G19_EXEC_PROOF" >> "$GITHUB_OUTPUT"
  exit 0
else
  echo "GATE FAILURE(S) DETECTED"
  exit 1
fi

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
G19_PROOF_MATERIAL=""

echo "== verification-tools gate suite =="
echo "python:   $PY"
echo "verifiers: $PYV , $SHV"
echo

# ---- helpers -------------------------------------------------------------
fail() { echo "  $1: FAIL - $2"; FAILED=1; }
pass() {
  echo "  $1: PASS ${2:-}"
  G19_PROOF_MATERIAL="${G19_PROOF_MATERIAL}PASS|${1}|${2:-}"$'\n'
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
ALLOWED='^(README\.md|SECURITY\.md|DISCLAIMER\.md|LICENSE|\.gitignore|\.gitattributes|\.github/workflows/ci\.yml|memoriaia/schema/[A-Za-z0-9._-]+\.sql|memoriaia/fixtures/[A-Za-z0-9._-]+\.sql|memoriaia/verify/verify-hashchain\.py|verify/verify-hashchain\.sh|tests/run-gates\.sh|tests/g19-v2-structural-check\.sh|tests/fixtures/g19-v2/(baseline-good|missing-proof-mutant|mutant-comment-only-sentinel|mutant-continue-on-error|mutant-folded-subshell-true-paren|mutant-forged-indirect-output-unreachable|mutant-forged-proof-output|mutant-gates-extraction-service-name-collision|mutant-gates-needs-skipped-blocker|mutant-if-false-run|mutant-job-continue-on-error|mutant-job-if-false|mutant-job-if-post-steps-expression|mutant-job-quoted-continue-on-error|mutant-job-quoted-if-false|mutant-job-yaml-alias-continue-on-error|mutant-job-yaml-alias-if-false|mutant-missing-sentinel|mutant-or-true-paren|mutant-or-true|mutant-semicolon-true|mutant-sentinel-echo-only-failure|mutant-sentinel-heredoc-inert|mutant-sentinel-exit-zero-expression|mutant-sentinel-invalid-proof-echo-branch|mutant-sentinel-trap-exit-zero|mutant-sentinel-uncalled-function|mutant-step-if-expression-run|mutant-step-quoted-continue-on-error|mutant-step-quoted-if-run|skipped-run_gates-mutant)\.yml)$'
UNEXPECTED="$(git ls-files | grep -vE "$ALLOWED" || true)"
SENSITIVE="$(git ls-files | grep -iE '\.(sqlite|sqlite3|db|pem|key|env|p12|pfx|crt)$|(^|/)id_(rsa|ed25519)' || true)"
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
G19_BASELINE_FIXTURE="baseline-good.yml"
G19_MUTANT_FIXTURES="
missing-proof-mutant.yml
mutant-comment-only-sentinel.yml
mutant-continue-on-error.yml
mutant-folded-subshell-true-paren.yml
mutant-forged-indirect-output-unreachable.yml
mutant-forged-proof-output.yml
mutant-gates-extraction-service-name-collision.yml
mutant-gates-needs-skipped-blocker.yml
mutant-if-false-run.yml
mutant-job-continue-on-error.yml
mutant-job-if-false.yml
mutant-job-if-post-steps-expression.yml
mutant-job-quoted-continue-on-error.yml
mutant-job-quoted-if-false.yml
mutant-job-yaml-alias-continue-on-error.yml
mutant-job-yaml-alias-if-false.yml
mutant-missing-sentinel.yml
mutant-or-true-paren.yml
mutant-or-true.yml
mutant-semicolon-true.yml
mutant-sentinel-echo-only-failure.yml
mutant-sentinel-heredoc-inert.yml
mutant-sentinel-exit-zero-expression.yml
mutant-sentinel-invalid-proof-echo-branch.yml
mutant-sentinel-trap-exit-zero.yml
mutant-sentinel-uncalled-function.yml
mutant-step-if-expression-run.yml
mutant-step-quoted-continue-on-error.yml
mutant-step-quoted-if-run.yml
skipped-run_gates-mutant.yml
"
G19_EXPECTED_FIXTURES="$G19_BASELINE_FIXTURE $G19_MUTANT_FIXTURES"

G19_FIXTURE_MISSING=0
for fixture in $G19_EXPECTED_FIXTURES; do
  if [ ! -f "$G19_FIXTURE_DIR/$fixture" ]; then
    fail "G-19 v2 fixture exists" "$fixture missing"
    G19_FIXTURE_MISSING=1
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
  if bash tests/g19-v2-structural-check.sh "$G19_FIXTURE_DIR/$G19_BASELINE_FIXTURE" >"$OUT" 2>&1; then
    pass "G-19 v2 baseline fixture passes"
  else
    fail "G-19 v2 baseline fixture passes" "$(tr '\n' ';' <"$OUT")"
  fi

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
  VT_G19_EXEC_PROOF="$(printf 'VT_G19_EXECUTED:%s\n%s' "$HEAD_SHA" "$G19_PROOF_MATERIAL" | sha256sum | awk '{print $1}')"
  echo "VT_G19_EXEC_PROOF=$VT_G19_EXEC_PROOF"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "vt_g19_exec_proof=$VT_G19_EXEC_PROOF" >> "$GITHUB_OUTPUT"
  exit 0
else
  echo "GATE FAILURE(S) DETECTED"
  exit 1
fi

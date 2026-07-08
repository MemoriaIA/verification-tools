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
ROOT="$(cd "$SCRIPT_DIR/.." && (cygpath -m "$(pwd)" 2>/dev/null || pwd -W 2>/dev/null || pwd))"
cd "$ROOT"
ROOT_PHYSICAL="$(pwd -P)"

reject_git_environment_poisoning() {
  for name in \
    GIT_DIR \
    GIT_WORK_TREE \
    GIT_EXEC_PATH \
    GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_CONFIG \
    GIT_CONFIG_GLOBAL \
    GIT_CONFIG_SYSTEM \
    GIT_CONFIG_NOSYSTEM \
    GIT_TRACE \
    GIT_TRACE_PACKET \
    GIT_TRACE_SETUP \
    GIT_TRACE_PERFORMANCE \
    GIT_SSH \
    GIT_SSH_COMMAND \
    GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES \
    GIT_PAGER
  do
    if printenv "$name" >/dev/null 2>&1; then
      echo "SETUP FAIL: proof-critical git environment variable is set ($name)" >&2
      exit 2
    fi
  done

  git_config_env="$(env | sed -n 's/^\(GIT_CONFIG_[^=]*\)=.*/\1/p' | head -n 1)"
  if [ -n "$git_config_env" ]; then
    echo "SETUP FAIL: proof-critical git config environment variable is set ($git_config_env)" >&2
    exit 2
  fi
}

gitdir_from_metadata() {
  if [ -d "$ROOT/.git" ]; then
    (cd "$ROOT/.git" && pwd -P)
    return
  fi
  if [ ! -f "$ROOT/.git" ]; then
    return 1
  fi
  gitdir_line="$(sed -n '1p' "$ROOT/.git")"
  case "$gitdir_line" in
    gitdir:\ *) gitdir_path="${gitdir_line#gitdir: }" ;;
    *) return 1 ;;
  esac
  case "$gitdir_path" in
    /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *) gitdir_path="$ROOT/$gitdir_path" ;;
  esac
  (cd "$gitdir_path" && pwd -P)
}

head_sha_from_metadata() {
  gitdir="$(gitdir_from_metadata)" || return 1
  common_gitdir="$gitdir"
  if [ -f "$gitdir/commondir" ]; then
    common_gitdir_path="$(sed -n '1p' "$gitdir/commondir" | tr -d '\r\n')"
    case "$common_gitdir_path" in
      /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
      *) common_gitdir_path="$gitdir/$common_gitdir_path" ;;
    esac
    common_gitdir="$(cd "$common_gitdir_path" && pwd -P)"
  fi
  [ -f "$gitdir/HEAD" ] || return 1
  head_line="$(sed -n '1p' "$gitdir/HEAD" | tr -d '\r\n')"
  case "$head_line" in
    ref:\ *)
      ref_name="${head_line#ref: }"
      if [ -f "$gitdir/$ref_name" ]; then
        sed -n '1p' "$gitdir/$ref_name" | tr -d '\r\n'
      elif [ -f "$common_gitdir/$ref_name" ]; then
        sed -n '1p' "$common_gitdir/$ref_name" | tr -d '\r\n'
      elif [ -f "$gitdir/packed-refs" ]; then
        awk -v ref="$ref_name" '$2 == ref { print $1; found = 1 } END { exit found ? 0 : 1 }' "$gitdir/packed-refs"
      elif [ -f "$common_gitdir/packed-refs" ]; then
        awk -v ref="$ref_name" '$2 == ref { print $1; found = 1 } END { exit found ? 0 : 1 }' "$common_gitdir/packed-refs"
      else
        return 1
      fi
      ;;
    *) printf '%s\n' "$head_line" ;;
  esac
}

is_trusted_git_path() {
  candidate="$1"
  case "$candidate" in
    /usr/bin/git|/bin/git|\
    /mingw64/bin/git|/mingw64/bin/git.exe|\
    /cmd/git|/cmd/git.exe|\
    /cygdrive/c/Program\ Files/Git/cmd/git|\
    /cygdrive/c/Program\ Files/Git/cmd/git.exe|\
    /cygdrive/c/Program\ Files/Git/bin/git|\
    /cygdrive/c/Program\ Files/Git/bin/git.exe|\
    /cygdrive/c/Program\ Files/Git/mingw64/bin/git|\
    /cygdrive/c/Program\ Files/Git/mingw64/bin/git.exe)
      return 0
      ;;
  esac
  return 1
}

resolve_trusted_git() {
  reject_git_environment_poisoning
  candidate="$(command -v git || true)"
  if [ -z "$candidate" ] || [ ! -x "$candidate" ]; then
    echo "SETUP FAIL: git executable is unavailable" >&2
    exit 2
  fi
  candidate_dir="$(cd "$(dirname "$candidate")" && pwd -P)"
  candidate="$candidate_dir/$(basename "$candidate")"
  if ! is_trusted_git_path "$candidate"; then
    echo "SETUP FAIL: git executable resolves outside trusted system paths ($candidate)" >&2
    exit 2
  fi
  manual_head="$(head_sha_from_metadata || true)"
  if ! printf '%s\n' "$manual_head" | grep -qE '^[0-9a-f]{40}$'; then
    echo "SETUP FAIL: could not resolve repository HEAD from git metadata" >&2
    exit 2
  fi
  git_version="$("$candidate" --version 2>/dev/null || true)"
  case "$git_version" in
    git\ version\ *) ;;
    *)
      echo "SETUP FAIL: git executable version is incoherent ($git_version)" >&2
      exit 2
      ;;
  esac
  manual_gitdir="$(gitdir_from_metadata || true)"
  candidate_gitdir="$("$candidate" rev-parse --git-dir 2>/dev/null || true)"
  case "$candidate_gitdir" in
    /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *) candidate_gitdir="$ROOT/$candidate_gitdir" ;;
  esac
  candidate_gitdir="$(cd "$candidate_gitdir" 2>/dev/null && pwd -P || true)"
  if [ -z "$candidate_gitdir" ] || [ "$candidate_gitdir" != "$manual_gitdir" ]; then
    echo "SETUP FAIL: git executable git-dir mismatch (metadata $manual_gitdir, git $candidate_gitdir)" >&2
    exit 2
  fi
  git_head="$("$candidate" rev-parse HEAD 2>/dev/null || true)"
  if [ "$git_head" != "$manual_head" ]; then
    echo "SETUP FAIL: git executable HEAD mismatch (metadata $manual_head, git $git_head)" >&2
    exit 2
  fi
  git_root="$("$candidate" rev-parse --show-toplevel 2>/dev/null || true)"
  git_root_physical="$(cd "$git_root" 2>/dev/null && pwd -P || true)"
  if [ "$git_root_physical" != "$ROOT_PHYSICAL" ]; then
    echo "SETUP FAIL: git executable root mismatch (expected $ROOT_PHYSICAL, got $git_root_physical)" >&2
    exit 2
  fi
  for required_blob in \
    .github/workflows/ci.yml \
    tests/run-gates.sh \
    tests/g19-v2-structural-check.sh \
    tests/lib/verify-tracked-workspace.sh
  do
    if ! "$candidate" cat-file -e "$manual_head:$required_blob" 2>/dev/null; then
      echo "SETUP FAIL: git executable cannot read proof-bound object ($manual_head:$required_blob)" >&2
      exit 2
    fi
  done
  printf '%s\n' "$candidate"
}

GIT_BIN="$(resolve_trusted_git)" || exit 2

assert_trusted_git_stable() {
  current="$(command -v git || true)"
  if [ -z "$current" ]; then
    echo "SETUP FAIL: git executable disappeared from PATH before proof emission" >&2
    exit 2
  fi
  current_dir="$(cd "$(dirname "$current")" && pwd -P)"
  current="$current_dir/$(basename "$current")"
  if [ "$current" != "$GIT_BIN" ]; then
    echo "SETUP FAIL: git executable changed during proof run (was $GIT_BIN, now $current)" >&2
    exit 2
  fi
}

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
  if ! "$GIT_BIN" ls-files --error-unmatch "$target" >/dev/null 2>&1 && ! "$GIT_BIN" ls-files "$target" | grep -q .; then
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
ALLOWED='^(README\.md|SECURITY\.md|DISCLAIMER\.md|LICENSE|\.gitignore|\.gitattributes|\.github/workflows/ci\.yml|memoriaia/schema/[A-Za-z0-9._-]+\.sql|memoriaia/fixtures/[A-Za-z0-9._-]+\.sql|memoriaia/verify/verify-hashchain\.py|verify/verify-hashchain\.sh|tests/run-gates\.sh|tests/g19-v2-structural-check\.sh|tests/lib/verify-tracked-workspace\.sh|tests/fixtures/g19-v2/(baseline-good|baseline-unrelated-github-output|missing-proof-mutant|mutant-comment-only-sentinel|mutant-continue-on-error|mutant-direct-github-output-proof-write|mutant-folded-subshell-true-paren|mutant-forged-indirect-output-unreachable|mutant-forged-proof-output|mutant-gates-extraction-service-name-collision|mutant-gate-steps-hidden-in-shell-string|mutant-gates-needs-skipped-blocker|mutant-job-default-shell-alias-or-true|mutant-job-default-shell-flow-map-or-true|mutant-job-default-shell-merge-key-or-true|mutant-job-default-shell-or-true|mutant-job-default-shell-run-alias-or-true|mutant-if-false-run|mutant-job-continue-on-error|mutant-job-env-git-work-tree|mutant-job-if-false|mutant-job-if-post-steps-expression|mutant-job-quoted-continue-on-error|mutant-job-quoted-if-false|mutant-job-yaml-alias-continue-on-error|mutant-job-yaml-alias-if-false|mutant-jobs-key-in-block-scalar|mutant-missing-sentinel|mutant-or-true-paren|mutant-or-true|mutant-prestep-bashenv-forged-output|mutant-prestep-github-path-python-poison|mutant-semicolon-true|mutant-sentinel-case-inert-guard|mutant-sentinel-echo-only-failure|mutant-sentinel-exit-in-else-branch|mutant-sentinel-false-and-brace-group|mutant-sentinel-heredoc-inert|mutant-sentinel-heredoc-numeric-delimiter|mutant-sentinel-exit-zero-expression|mutant-sentinel-fake-outcome-comparison|mutant-sentinel-invalid-proof-echo-branch|mutant-sentinel-invalid-proof-elif-exit|mutant-sentinel-invalid-proof-nested-inert-exit|mutant-sentinel-missing-proof-elif-exit|mutant-sentinel-missing-proof-nested-inert-exit|mutant-sentinel-outcome-elif-exit|mutant-sentinel-outcome-nested-inert-exit|mutant-sentinel-proof-array-overwrite|mutant-sentinel-proof-declare-overwrite|mutant-sentinel-proof-nameref-overwrite|mutant-sentinel-proof-parameter-default|mutant-sentinel-proof-overwrite-constant|mutant-sentinel-quoted-continue-on-error|mutant-sentinel-skipped-or-group|mutant-sentinel-split-line-function|mutant-sentinel-step-if-skipped|mutant-sentinel-trap-exit-zero|mutant-sentinel-uncalled-function|mutant-sentinel-unreachable-invalid-proof-guard|mutant-sentinel-unreachable-missing-proof-guard|mutant-sentinel-while-false-inert-guard|mutant-step-env-git-object-directory|mutant-step-if-expression-run|mutant-step-quoted-continue-on-error|mutant-step-quoted-if-run|mutant-workflow-default-shell-alias-or-true|mutant-workflow-default-shell-flow-map-or-true|mutant-workflow-default-shell-merge-key-or-true|mutant-workflow-default-shell-or-true|mutant-workflow-default-shell-run-alias-or-true|mutant-workflow-env-git-dir|skipped-run_gates-mutant)\.yml)$'
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
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|baseline-no-working-directory-safe|mutant-prestep-shadow-run-gates-stub|mutant-prestep-shadow-structural-checker-stub|mutant-prestep-shadow-verifier-stub|mutant-step-working-directory-shadow-tree|mutant-job-working-directory-shadow-tree|mutant-prestep-block-ansi-octal-137-env|mutant-prestep-block-ansi-octal-137-output-proof|mutant-prestep-block-ansi-octal-137-path|mutant-prestep-block-ansi-octal-bashenv|mutant-prestep-source-github-env|mutant-prestep-dot-github-env|mutant-inline-run-single-quoted-doubled-quote-github-env|mutant-sentinel-proof-variable-option-plain-nameref-overwrite|mutant-prestep-command-substitution-bash-c-github-env|mutant-prestep-bash-ec-github-env|mutant-prestep-process-substitution-bash-github-env|mutant-prestep-git-checkout-head-drift|mutant-gate-post-verify-run-gates-rewrite|mutant-gate-missing-ci-yml-verify|mutant-gate-missing-helper-source|mutant-sentinel-extra-command|mutant-sentinel-v3-proof-preimage|mutant-workflow-dispatch-enabled|mutant-workflow-dispatch-flow-sequence|mutant-prestep-command-git-checkout-head-drift|mutant-sentinel-printf-redirect-side-effect|mutant-prestep-truncate-run-gates|mutant-gate-inline-git-checkout-before-run|mutant-prestep-env-git-checkout-head-drift|mutant-prestep-usrbin-git-checkout-head-drift|mutant-prestep-git-C-checkout-head-drift|mutant-prestep-tee-run-gates|mutant-prestep-colon-redir-run-gates|mutant-sentinel-exec-printf-side-effect|mutant-sentinel-builtin-printf-side-effect|mutant-sentinel-expected-proof-overwrite}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|mutant-workflow-env-git-dir|mutant-job-env-git-work-tree|mutant-step-env-git-object-directory}"
ALLOWED="${ALLOWED/skipped-run_gates-mutant/skipped-run_gates-mutant|mutant-workflow-dispatch-block-sequence|mutant-prestep-var-run-gates-writer|mutant-prestep-write-trusted-git|mutant-workflow-env-git-namespace|mutant-job-env-git-ceiling-directories|mutant-job-env-git-pager}"
TRACKED_FILES="$WORK/tracked-files.txt"
if ! "$GIT_BIN" ls-files >"$TRACKED_FILES"; then
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

FAKE_GIT_DIR="$WORK/fake-git-bin"
mkdir -p "$FAKE_GIT_DIR"
FAKE_GIT_HEAD="$(head_sha_from_metadata)"
cat > "$FAKE_GIT_DIR/git" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "--version ") printf '%s\n' "git version 9.99.fake" ;;
  "rev-parse HEAD") printf '%s\n' "__FAKE_GIT_HEAD__" ;;
  "rev-parse --git-dir") printf '%s\n' ".git" ;;
  "rev-parse --show-toplevel") pwd ;;
  "cat-file -e") exit 0 ;;
  "cat-file blob") printf '%s\n' "fake blob payload" ;;
  *) exit 0 ;;
esac
SH
sed -i "s/__FAKE_GIT_HEAD__/$FAKE_GIT_HEAD/g" "$FAKE_GIT_DIR/git"
chmod +x "$FAKE_GIT_DIR/git"
if ( PATH="$FAKE_GIT_DIR:$PATH"; resolve_trusted_git ) >"$WORK/fake-git-resolve.out" 2>&1; then
  fail "G-19 trusted git rejects PATH shadow" "fake git was accepted from $FAKE_GIT_DIR"
else
  pass "G-19 trusted git rejects PATH shadow"
fi

for poison_name in \
  GIT_EXEC_PATH \
  GIT_DIR \
  GIT_WORK_TREE \
  GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_CONFIG \
  GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM \
  GIT_CONFIG_NOSYSTEM \
  GIT_TRACE \
  GIT_TRACE_PACKET \
  GIT_TRACE_SETUP \
  GIT_TRACE_PERFORMANCE \
  GIT_SSH \
  GIT_SSH_COMMAND \
  GIT_NAMESPACE \
  GIT_CEILING_DIRECTORIES \
  GIT_PAGER
do
  if (
    export "$poison_name=$WORK/poison"
    reject_git_environment_poisoning
  ) >"$WORK/git-env-poison-$poison_name.out" 2>&1; then
    fail "G-19 git env poisoning rejects $poison_name" "$poison_name unexpectedly passed"
  else
    pass "G-19 git env poisoning rejects $poison_name"
  fi
done

HELPER_WORKTREE="$WORK/helper-worktree"
rm -rf "$HELPER_WORKTREE"
if "$GIT_BIN" worktree add --detach "$HELPER_WORKTREE" "$("$GIT_BIN" rev-parse HEAD)" >/dev/null 2>&1; then
  if (
    cd "$HELPER_WORKTREE" &&
    VT_G19_CHECKOUT_SHA="$("$GIT_BIN" rev-parse HEAD)" &&
    export VT_G19_CHECKOUT_SHA &&
    . tests/lib/verify-tracked-workspace.sh &&
    verify_tracked_workspace_file tests/run-gates.sh
  ) >"$OUT" 2>&1; then
    pass "G-19 tracked workspace helper accepts clean blob"
  else
    fail "G-19 tracked workspace helper accepts clean blob" "$(tr '\n' ';' <"$OUT")"
  fi
  if (
    cd "$HELPER_WORKTREE" &&
    printf '\n# tampered by helper self-test\n' >> tests/run-gates.sh &&
    VT_G19_CHECKOUT_SHA="$("$GIT_BIN" rev-parse HEAD)" &&
    export VT_G19_CHECKOUT_SHA &&
    . tests/lib/verify-tracked-workspace.sh &&
    verify_tracked_workspace_file tests/run-gates.sh
  ) >"$OUT" 2>&1; then
    fail "G-19 tracked workspace helper rejects disk/blob drift" "tampered file unexpectedly passed"
  else
    pass "G-19 tracked workspace helper rejects disk/blob drift"
  fi
  if (
    cd "$HELPER_WORKTREE" &&
    VT_G19_CHECKOUT_SHA="ffffffffffffffffffffffffffffffffffffffff" &&
    export VT_G19_CHECKOUT_SHA &&
    . tests/lib/verify-tracked-workspace.sh &&
    verify_tracked_workspace_file tests/run-gates.sh
  ) >"$OUT" 2>&1; then
    fail "G-19 tracked workspace helper rejects missing object" "missing blob unexpectedly passed"
  else
    pass "G-19 tracked workspace helper rejects missing object"
  fi
  "$GIT_BIN" worktree remove --force "$HELPER_WORKTREE" >/dev/null 2>&1 || rm -rf "$HELPER_WORKTREE"
else
  fail "G-19 tracked workspace helper worktree setup" "git worktree add failed"
  rm -rf "$HELPER_WORKTREE"
fi

G19_FIXTURE_DIR="tests/fixtures/g19-v2"
G19_BASELINE_FIXTURES="
baseline-good.yml
baseline-anonymous-checkout.yml
baseline-anonymous-env-first.yml
baseline-escaped-x-key.yml
baseline-inline-anonymous-run.yml
baseline-inline-run-decoded-safe.yml
baseline-inline-run-quoted-continuation-safe.yml
baseline-no-working-directory-safe.yml
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
mutant-inline-run-single-quoted-doubled-quote-github-env.yml
mutant-job-working-directory-shadow-tree.yml
mutant-prestep-bash-ec-github-env.yml
mutant-prestep-block-ansi-octal-137-env.yml
mutant-prestep-block-ansi-octal-137-output-proof.yml
mutant-prestep-block-ansi-octal-137-path.yml
mutant-prestep-block-ansi-octal-bashenv.yml
mutant-prestep-command-substitution-bash-c-github-env.yml
mutant-prestep-dot-github-env.yml
mutant-prestep-git-checkout-head-drift.yml
mutant-prestep-process-substitution-bash-github-env.yml
mutant-prestep-shadow-run-gates-stub.yml
mutant-prestep-shadow-structural-checker-stub.yml
mutant-prestep-shadow-verifier-stub.yml
mutant-prestep-source-github-env.yml
mutant-gate-missing-ci-yml-verify.yml
mutant-gate-missing-helper-source.yml
mutant-gate-post-verify-run-gates-rewrite.yml
mutant-sentinel-extra-command.yml
mutant-sentinel-v3-proof-preimage.yml
mutant-workflow-dispatch-enabled.yml
mutant-workflow-dispatch-block-sequence.yml
mutant-workflow-dispatch-flow-sequence.yml
mutant-prestep-command-git-checkout-head-drift.yml
mutant-sentinel-printf-redirect-side-effect.yml
mutant-prestep-truncate-run-gates.yml
mutant-prestep-var-run-gates-writer.yml
mutant-prestep-write-trusted-git.yml
mutant-gate-inline-git-checkout-before-run.yml
mutant-prestep-env-git-checkout-head-drift.yml
mutant-prestep-usrbin-git-checkout-head-drift.yml
mutant-prestep-git-C-checkout-head-drift.yml
mutant-prestep-tee-run-gates.yml
mutant-prestep-colon-redir-run-gates.yml
mutant-sentinel-exec-printf-side-effect.yml
mutant-sentinel-builtin-printf-side-effect.yml
mutant-sentinel-expected-proof-overwrite.yml
mutant-sentinel-proof-variable-option-plain-nameref-overwrite.yml
mutant-step-working-directory-shadow-tree.yml
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
mutant-step-env-git-object-directory.yml
mutant-step-quoted-continue-on-error.yml
mutant-step-quoted-if-run.yml
mutant-step-uses-upload-artifact.yml
mutant-workflow-env-path-poison.yml
mutant-workflow-env-git-dir.yml
mutant-workflow-env-git-namespace.yml
mutant-job-env-git-work-tree.yml
mutant-job-env-git-ceiling-directories.yml
mutant-job-env-git-pager.yml
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
  elif ! "$GIT_BIN" ls-files --error-unmatch "$fixture_path" >/dev/null 2>&1; then
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

WHITESPACE_REPO="$WORK/whitespace-range-repo"
mkdir -p "$WHITESPACE_REPO"
WHITESPACE_OUT="$ROOT/$OUT"
if (
  cd "$WHITESPACE_REPO" &&
  git init -q &&
  git config user.name "verification-tools-gates" &&
  git config user.email "verification-tools@example.invalid" &&
  git config core.autocrlf false &&
  printf 'alpha\n' > clean.txt &&
  git add clean.txt &&
  git commit -q -m "base" &&
  WS_BASE_SHA="$(git rev-parse HEAD)" &&
  printf 'alpha   \n' > clean.txt &&
  git add clean.txt &&
  git commit -q -m "head-with-whitespace" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  git diff --check >"$WHITESPACE_OUT" 2>&1
); then
  pass "G-20 bare git diff --check misses committed whitespace on clean worktree"
else
  fail "G-20 bare git diff --check misses committed whitespace on clean worktree" "$(tr '\n' ';' <"$WHITESPACE_OUT")"
fi

if (
  cd "$WHITESPACE_REPO" &&
  WS_BASE_SHA="$(git rev-parse HEAD~1)" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  git -c core.attributesFile=/dev/null diff --check "$WS_BASE_SHA..$WS_HEAD_SHA" >"$WHITESPACE_OUT" 2>&1
); then
  fail "G-21 range-aware whitespace guard rejects committed whitespace" "range-aware diff unexpectedly passed"
else
  pass "G-21 range-aware whitespace guard rejects committed whitespace"
fi

if (
  cd "$WHITESPACE_REPO" &&
  WS_BASE_SHA="0000000000000000000000000000000000000000" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  git cat-file -e "$WS_BASE_SHA^{commit}" 2>/dev/null &&
  git diff --check "$WS_BASE_SHA..$WS_HEAD_SHA" >"$WHITESPACE_OUT" 2>&1
); then
  fail "G-22 whitespace guard rejects invalid base SHA" "invalid base SHA unexpectedly passed"
else
  pass "G-22 whitespace guard rejects invalid base SHA"
fi

if (
  cd "$WHITESPACE_REPO" &&
  git checkout -q HEAD~1 &&
  WS_BASE_SHA="$(git rev-parse HEAD)" &&
  printf 'beta\n' > clean.txt &&
  git add clean.txt &&
  git commit -q -m "head-clean" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  git -c core.attributesFile=/dev/null diff --check "$WS_BASE_SHA..$WS_HEAD_SHA" >"$WHITESPACE_OUT" 2>&1
); then
  pass "G-23 range-aware whitespace guard passes clean committed range"
else
  fail "G-23 range-aware whitespace guard passes clean committed range" "$(tr '\n' ';' <"$WHITESPACE_OUT")"
fi

WHITESPACE_PR_REPO="$WORK/whitespace-pr-merge-base-repo"
mkdir -p "$WHITESPACE_PR_REPO"
if (
  cd "$WHITESPACE_PR_REPO" &&
  git init -q &&
  git config user.name "verification-tools-gates" &&
  git config user.email "verification-tools@example.invalid" &&
  git config core.autocrlf false &&
  printf 'legacy   \n' > inherited.txt &&
  git add inherited.txt &&
  git commit -q -m "branch-point-with-legacy-whitespace" &&
  git branch feature &&
  printf 'legacy\n' > inherited.txt &&
  git add inherited.txt &&
  git commit -q -m "main-cleans-legacy-whitespace" &&
  WS_BASE_SHA="$(git rev-parse HEAD)" &&
  printf '%s' "$WS_BASE_SHA" > .ws-base-sha &&
  git checkout -q feature &&
  printf 'feature\n' > feature.txt &&
  git add feature.txt &&
  git commit -q -m "feature-does-not-touch-legacy-whitespace" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  git -c core.attributesFile=/dev/null diff --check "$WS_BASE_SHA..$WS_HEAD_SHA" >"$WHITESPACE_OUT" 2>&1
); then
  fail "G-24 two-dot whitespace diff false-positives after base cleanup" "two-dot diff unexpectedly passed"
else
  pass "G-24 two-dot whitespace diff false-positives after base cleanup"
fi

if (
  cd "$WHITESPACE_PR_REPO" &&
  WS_BASE_SHA="$(cat .ws-base-sha)" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  git -c core.attributesFile=/dev/null diff --check "$WS_BASE_SHA...$WS_HEAD_SHA" >"$WHITESPACE_OUT" 2>&1
); then
  pass "G-25 triple-dot whitespace diff uses merge base for pull requests"
else
  fail "G-25 triple-dot whitespace diff uses merge base for pull requests" "$(tr '\n' ';' <"$WHITESPACE_OUT")"
fi

WHITESPACE_ATTR_REPO="$WORK/whitespace-attributes-repo"
mkdir -p "$WHITESPACE_ATTR_REPO"
if (
  cd "$WHITESPACE_ATTR_REPO" &&
  git init -q &&
  git config user.name "verification-tools-gates" &&
  git config user.email "verification-tools@example.invalid" &&
  git config core.autocrlf false &&
  printf 'clean\n' > tracked.txt &&
  git add tracked.txt &&
  git commit -q -m "base-clean" &&
  WS_BASE_SHA="$(git rev-parse HEAD)" &&
  printf '* -whitespace\n' > .gitattributes &&
  printf 'dirty   \n' > tracked.txt &&
  git add .gitattributes tracked.txt &&
  git commit -q -m "head-relaxes-whitespace-attributes" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  git diff --name-only "$WS_BASE_SHA..$WS_HEAD_SHA" | grep -qE '(^|/)\.gitattributes$'
); then
  pass "G-26 whitespace guard rejects checked-range .gitattributes changes"
else
  fail "G-26 whitespace guard rejects checked-range .gitattributes changes" ".gitattributes change was not detected in the checked range"
fi

WHITESPACE_PIPEFAIL_REPO="$WORK/whitespace-attributes-pipefail-repo"
mkdir -p "$WHITESPACE_PIPEFAIL_REPO"
if (
  cd "$WHITESPACE_PIPEFAIL_REPO" &&
  git init -q &&
  git config user.name "verification-tools-gates" &&
  git config user.email "verification-tools@example.invalid" &&
  git config core.autocrlf false &&
  printf 'clean\n' > tracked.txt &&
  git add tracked.txt &&
  git commit -q -m "base-clean" &&
  WS_BASE_SHA="$(git rev-parse HEAD)" &&
  printf '* -whitespace\n' > .gitattributes &&
  i=0 &&
  while [ "$i" -lt 512 ]; do
    printf 'filler %s\n' "$i" > "$(printf 'z%03d.txt' "$i")" &&
    i=$((i + 1))
  done &&
  git add .gitattributes z*.txt &&
  git commit -q -m "head-many-files-with-attributes" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  set -o pipefail &&
  WHITESPACE_CHANGED_PATHS="$(git diff --name-status --no-renames "$WS_BASE_SHA..$WS_HEAD_SHA")" &&
  WS_ATTR_CHANGED=0 &&
  while IFS= read -r ws_line; do
    [ -z "$ws_line" ] && continue
    ws_path="${ws_line##*	}"
    case "$ws_path" in
      .gitattributes|*/.gitattributes)
        WS_ATTR_CHANGED=1
        ;;
    esac
  done <<EOF
$WHITESPACE_CHANGED_PATHS
EOF
  [ "$WS_ATTR_CHANGED" -eq 1 ]
); then
  pass "G-27 pipefail-safe .gitattributes detection remains stable on large diffs"
else
  fail "G-27 pipefail-safe .gitattributes detection remains stable on large diffs" "status-based detection missed .gitattributes with pipefail enabled"
fi

if (
  cd "$WHITESPACE_PIPEFAIL_REPO" &&
  WS_BASE_SHA="$(git rev-parse HEAD~1)" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  WHITESPACE_CHANGED_PATHS="$(git diff --name-status --no-renames "$WS_BASE_SHA..$WS_HEAD_SHA")" &&
  WS_ATTR_CHANGED=0 &&
  while IFS= read -r ws_line; do
    [ -z "$ws_line" ] && continue
    ws_path="${ws_line##*	}"
    case "$ws_path" in
      .gitattributes|*/.gitattributes)
        WS_ATTR_CHANGED=1
        ;;
    esac
  done <<EOF
$WHITESPACE_CHANGED_PATHS
EOF
  [ "$WS_ATTR_CHANGED" -eq 1 ]
); then
  pass "G-28 status-based .gitattributes detection survives pipefail scenarios"
else
  fail "G-28 status-based .gitattributes detection survives pipefail scenarios" "status-based detection did not mark .gitattributes as changed"
fi

WHITESPACE_RENAME_REPO="$WORK/whitespace-attributes-rename-repo"
mkdir -p "$WHITESPACE_RENAME_REPO"
if (
  cd "$WHITESPACE_RENAME_REPO" &&
  git init -q &&
  git config user.name "verification-tools-gates" &&
  git config user.email "verification-tools@example.invalid" &&
  git config core.autocrlf false &&
  printf '*.txt whitespace=tab-in-indent\n' > .gitattributes &&
  printf 'clean\n' > tracked.txt &&
  git add .gitattributes tracked.txt &&
  git commit -q -m "base-with-gitattributes" &&
  WS_BASE_SHA="$(git rev-parse HEAD)" &&
  git mv .gitattributes attrs &&
  printf '\tindented\n' > tracked.txt &&
  git add attrs tracked.txt &&
  git commit -q -m "rename-away-gitattributes" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  ! git diff --name-only "$WS_BASE_SHA..$WS_HEAD_SHA" | grep -qE '(^|/)\.gitattributes$'
); then
  pass "G-29 name-only .gitattributes detection misses rename-away sources"
else
  fail "G-29 name-only .gitattributes detection misses rename-away sources" "name-only unexpectedly detected renamed-away .gitattributes"
fi

if (
  cd "$WHITESPACE_RENAME_REPO" &&
  WS_BASE_SHA="$(git rev-parse HEAD~1)" &&
  WS_HEAD_SHA="$(git rev-parse HEAD)" &&
  WHITESPACE_CHANGED_PATHS="$(git diff --name-status --no-renames "$WS_BASE_SHA..$WS_HEAD_SHA")" &&
  WS_ATTR_CHANGED=0 &&
  while IFS= read -r ws_line; do
    [ -z "$ws_line" ] && continue
    ws_path="${ws_line##*	}"
    case "$ws_path" in
      .gitattributes|*/.gitattributes)
        WS_ATTR_CHANGED=1
        ;;
    esac
  done <<EOF
$WHITESPACE_CHANGED_PATHS
EOF
  [ "$WS_ATTR_CHANGED" -eq 1 ]
); then
  pass "G-30 status-based .gitattributes detection catches rename-away sources"
else
  fail "G-30 status-based .gitattributes detection catches rename-away sources" "status-based detection missed renamed-away .gitattributes"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  HEAD_SHA="$("$GIT_BIN" rev-parse HEAD 2>/dev/null || printf 'unknown')"
  PROOF_PR_HEAD_SHA="${VT_G19_PR_HEAD_SHA:-$HEAD_SHA}"
  PROOF_PR_BASE_SHA="${VT_G19_PR_BASE_SHA:-$HEAD_SHA}"
  PROOF_CHECKOUT_SHA="${VT_G19_CHECKOUT_SHA:-$HEAD_SHA}"
  for proof_sha in "$PROOF_PR_HEAD_SHA" "$PROOF_PR_BASE_SHA" "$PROOF_CHECKOUT_SHA"; do
    if ! printf '%s\n' "$proof_sha" | grep -qE '^[0-9a-f]{40}$'; then
      echo "SETUP FAIL: invalid VT_G19 proof SHA input ($proof_sha)"
      exit 2
    fi
  done
  EXECUTED_HEAD_SHA="$("$GIT_BIN" rev-parse HEAD)"
  if [ "$PROOF_CHECKOUT_SHA" != "$EXECUTED_HEAD_SHA" ]; then
    echo "SETUP FAIL: VT_G19_CHECKOUT_SHA does not match executed worktree HEAD ($EXECUTED_HEAD_SHA)"
    exit 2
  fi
  assert_trusted_git_stable
  VT_G19_CHECKOUT_SHA="$PROOF_CHECKOUT_SHA"
  export VT_G19_CHECKOUT_SHA
  . tests/lib/verify-tracked-workspace.sh
  for proof_file in \
    .github/workflows/ci.yml \
    tests/run-gates.sh \
    tests/g19-v2-structural-check.sh \
    tests/lib/verify-tracked-workspace.sh \
    memoriaia/verify/verify-hashchain.py \
    verify/verify-hashchain.sh
  do
    verify_tracked_workspace_file "$proof_file"
  done
  "$GIT_BIN" ls-files 'tests/fixtures/g19-v2/*.yml' |
    while IFS= read -r proof_fixture; do
      verify_tracked_workspace_file "$proof_fixture"
    done || exit 2
  tracked_blob_sha256() {
    if ! "$GIT_BIN" cat-file -e "$PROOF_CHECKOUT_SHA:$1" 2>/dev/null; then
      echo "SETUP FAIL: proof-bound blob is missing ($PROOF_CHECKOUT_SHA:$1)" >&2
      return 2
    fi
    "$GIT_BIN" cat-file blob "$PROOF_CHECKOUT_SHA:$1" | sha256sum | awk '{print $1}'
  }
  fixture_manifest_sha256() {
    fixture_manifest="$WORK/g19-fixture-manifest.txt"
    : > "$fixture_manifest"
    "$GIT_BIN" ls-files 'tests/fixtures/g19-v2/*.yml' |
      while IFS= read -r fixture; do
        fixture_sha="$(tracked_blob_sha256 "$fixture")" || exit 2
        printf '%s  %s\n' "$fixture_sha" "$fixture"
      done > "$fixture_manifest" || return 2
    sha256sum "$fixture_manifest" | awk '{print $1}'
  }
  RUN_GATES_SHA="$(tracked_blob_sha256 "tests/run-gates.sh")" || exit 2
  STRUCTURAL_CHECK_SHA="$(tracked_blob_sha256 "tests/g19-v2-structural-check.sh")" || exit 2
  CI_YML_SHA="$(tracked_blob_sha256 ".github/workflows/ci.yml")" || exit 2
  WORKSPACE_HELPER_SHA="$(tracked_blob_sha256 "tests/lib/verify-tracked-workspace.sh")" || exit 2
  VERIFY_PY_SHA="$(tracked_blob_sha256 "memoriaia/verify/verify-hashchain.py")" || exit 2
  VERIFY_SH_SHA="$(tracked_blob_sha256 "verify/verify-hashchain.sh")" || exit 2
  G19_FIXTURE_MANIFEST_SHA="$(fixture_manifest_sha256)" || exit 2
  VT_G19_EXEC_PROOF="$(
    printf 'VT_G19_EXECUTED:v4\nPR_HEAD:%s\nPR_BASE:%s\nCHECKOUT:%s\nCI_YML:%s\nRUN_GATES:%s\nSTRUCTURAL:%s\nWORKSPACE_HELPER:%s\nVERIFY_PY:%s\nVERIFY_SH:%s\nFIXTURES:%s\n' \
      "$PROOF_PR_HEAD_SHA" "$PROOF_PR_BASE_SHA" "$PROOF_CHECKOUT_SHA" \
      "$CI_YML_SHA" "$RUN_GATES_SHA" "$STRUCTURAL_CHECK_SHA" "$WORKSPACE_HELPER_SHA" "$VERIFY_PY_SHA" "$VERIFY_SH_SHA" "$G19_FIXTURE_MANIFEST_SHA" |
      sha256sum |
      awk '{print $1}'
  )"
  echo "VT_G19_EXEC_PROOF=$VT_G19_EXEC_PROOF"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "vt_g19_exec_proof=$VT_G19_EXEC_PROOF" >> "$GITHUB_OUTPUT"
  echo "ALL GATES PASS"
  exit 0
else
  echo "GATE FAILURE(S) DETECTED"
  exit 1
fi

#!/usr/bin/env bash
# run-gates.sh — Regression gate suite for the verification-tools proof surface.
#
# Runs G-1..G-10. Confirms the Python verifier works, the .gitignore functions,
# the README contains no forbidden claims, DISCLAIMER.md is present, and — most
# importantly — that the documented known limitation (tail truncation passing as
# VALID) is empirically confirmed rather than an error.
#
# Usage:  bash tests/run-gates.sh
# Exit:   0 if all hard gates pass; nonzero on the first hard-gate failure.
#
# Portability: prefers python3, falls back to python. The repo targets Python
# 3.8+ (standard library only); some Windows installs expose only "python".
# PYTHONIOENCODING=utf-8 is exported so the verifier's output never depends on
# the console code page (this mirrors the F-2 fix and keeps gates deterministic).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# --- portable Python interpreter resolution ---
PY="$(command -v python3 || true)"
[ -z "$PY" ] && PY="$(command -v python || true)"
[ -z "$PY" ] && { echo "FATAL: no python3/python interpreter on PATH"; exit 2; }
export PYTHONIOENCODING=utf-8

VERIFIER="memoriaia/verify/verify-hashchain.py"
FIXTURE="memoriaia/fixtures/example-vault.sql"
ZERO64="0000000000000000000000000000000000000000000000000000000000000000"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== verification-tools gate suite =="
echo "python:   $PY"
echo "verifier: $VERIFIER"
echo

# G-1: Python syntax check
"$PY" -m py_compile "$VERIFIER" && echo "G-1 PASS" || { echo "G-1 FAIL"; exit 1; }

# G-2: Fixture loads into SQLite (suppress the PRAGMA journal_mode echo)
sqlite3 "$WORK/gates-vault.sqlite" < "$FIXTURE" >/dev/null && echo "G-2 PASS" || { echo "G-2 FAIL"; exit 1; }

# G-3: Verifier PASS on valid fixture (exit 0)
"$PY" "$VERIFIER" --vault "$WORK/gates-vault.sqlite" >/dev/null && echo "G-3 PASS" || { echo "G-3 FAIL"; exit 1; }

# G-4: Verifier FAIL on tampered interior record (nonzero exit).
# The fixture installs append-only triggers, so the UPDATE trigger is dropped
# first to simulate an attacker who bypassed enforcement at the DB layer —
# exactly the scenario the README says the hash chain still detects.
sqlite3 "$WORK/gates-tampered.sqlite" < "$FIXTURE" >/dev/null
sqlite3 "$WORK/gates-tampered.sqlite" \
  "DROP TRIGGER IF EXISTS prevent_vault_update; UPDATE vault_entries SET hash='$ZERO64' WHERE sequence=2;" >/dev/null
if "$PY" "$VERIFIER" --vault "$WORK/gates-tampered.sqlite" >/dev/null 2>&1; then
  echo "G-4 FAIL (tampered vault passed as valid)"; exit 1
else
  echo "G-4 PASS (interior tampering detected, nonzero exit)"
fi

# G-5: Tail-truncated vault exits 0 and does NOT claim completeness.
# Build a 2-of-3 vault (newest record removed). The remaining chain is still
# internally consistent -> exit 0. This confirms the documented known
# limitation is real behaviour, not a bug.
sqlite3 "$WORK/gates-tail-truncated.sqlite" < "$FIXTURE" >/dev/null
sqlite3 "$WORK/gates-tail-truncated.sqlite" \
  "DROP TRIGGER IF EXISTS prevent_vault_delete; DELETE FROM vault_entries WHERE sequence=3;" >/dev/null
if "$PY" "$VERIFIER" --vault "$WORK/gates-tail-truncated.sqlite" >/dev/null; then
  echo "G-5 EXPECTED PASS (known limitation confirmed: tail truncation undetectable)"
else
  echo "G-5 UNEXPECTED FAIL (truncated-but-consistent vault should verify)"; exit 1
fi

# G-6: .gitignore actually excludes .claude/
git check-ignore -v .claude/test >/dev/null && echo "G-6 PASS" || { echo "G-6 FAIL: .gitignore not working"; exit 1; }

# G-7: No forbidden claim phrases in README.md
if grep -iE "certified|compliant|court-admissible|legally binding|enterprise-ready|production-ready|audit-passed|proves truth" README.md >/dev/null; then
  echo "G-7 FAIL: forbidden phrase found"; exit 1
else
  echo "G-7 PASS"
fi

# G-8: DISCLAIMER.md exists
test -f DISCLAIMER.md && echo "G-8 PASS" || { echo "G-8 FAIL"; exit 1; }

# G-9: no phantom requirements.txt
if [ ! -f memoriaia/verify/requirements.txt ]; then
  echo "G-9 PASS (no phantom file)"
else
  echo "G-9 NOTE: requirements.txt present, verify content"
fi

# G-10: No unexpected tracked file types (no vault data, private keys, EEE
# artifacts). LICENSE is the one legitimate extensionless tracked file.
UNEXPECTED="$(git ls-files | grep -vE '\.(sql|py|sh|md|txt|gitignore)$' | grep -vE '(^|/)LICENSE$' || true)"
if [ -n "$UNEXPECTED" ]; then
  echo "G-10 WARN: unexpected file types:"; echo "$UNEXPECTED"
else
  echo "G-10 PASS"
fi

echo
echo "ALL GATES COMPLETE"

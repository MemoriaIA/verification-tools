#!/usr/bin/env bash
# verify-hashchain.sh — Bash compatibility wrapper for MemoriaIA vault verification.
#
# Usage:
#   bash verify-hashchain.sh path/to/vault.sqlite
#
# Requirements:
#   - bash
#   - python3 or python (3.8+)
#
# The Python verifier under memoriaia/verify/ is the canonical implementation.
# This wrapper exists for existing shell-first usage and deliberately delegates
# the full read/parse/hash path to that verifier so bash delimiter parsing
# cannot diverge from Python.

set -euo pipefail

VAULT="${1:-}"

if [[ -z "$VAULT" ]]; then
    echo "Usage: $0 path/to/vault.sqlite" >&2
    exit 2
fi

if [[ ! -f "$VAULT" ]]; then
    echo "Error: vault file not found: $VAULT" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PY_VERIFIER="$ROOT_DIR/memoriaia/verify/verify-hashchain.py"

PY="${PYTHON:-}"
if [[ -z "$PY" ]]; then
    PY="$(command -v python3 || true)"
fi
if [[ -z "$PY" ]]; then
    PY="$(command -v python || true)"
fi
if [[ -z "$PY" ]]; then
    echo "Error: no python3/python interpreter on PATH" >&2
    exit 2
fi

export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
PY_VERIFIER_ARG="$PY_VERIFIER"
VAULT_ARG="$VAULT"
if command -v cygpath >/dev/null 2>&1; then
    PY_VERIFIER_ARG="$(cygpath -w "$PY_VERIFIER")"
    VAULT_ARG="$(cygpath -w "$VAULT")"
fi

exec "$PY" "$PY_VERIFIER_ARG" --vault "$VAULT_ARG"

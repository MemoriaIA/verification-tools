#!/usr/bin/env bash
# verify-release-manifest.sh - shell wrapper for the signed release manifest verifier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PY_VERIFIER="$ROOT_DIR/memoriaia/verify/verify-release-manifest.py"

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
ROOT_DIR_ARG="$ROOT_DIR"
if command -v cygpath >/dev/null 2>&1; then
    PY_VERIFIER_ARG="$(cygpath -w "$PY_VERIFIER")"
    ROOT_DIR_ARG="$(cygpath -w "$ROOT_DIR")"
fi

exec "$PY" "$PY_VERIFIER_ARG" --repo-root "$ROOT_DIR_ARG" "$@"

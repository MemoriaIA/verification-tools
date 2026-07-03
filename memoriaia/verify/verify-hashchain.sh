#!/usr/bin/env bash
# verify-hashchain.sh — Independent hash-chain verifier for MemoriaIA vaults.
#
# Usage:
#   bash verify-hashchain.sh path/to/vault.sqlite
#
# Requirements:
#   - sqlite3 (CLI)
#   - python (3.8+) for canonical JSON + SHA-256 (standard library only)
#
# This script delegates hash computation to a minimal inline Python function
# to ensure RFC 8785 / JCS canonicalization is applied correctly.
# The SQLite query and chain-linking logic are handled in shell.
#
# Verification model:
#   Hashes are computed over the encrypted payload as stored — no decryption.
#   See README.md § Mathematical Specification for the full field contract.
#
# Exit codes:
#   0 — chain valid
#   1 — chain invalid
#   2 — usage error

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

# Inline Python for canonical JSON + SHA-256.
# Called once per record with six positional arguments.
HASH_FN='
import sys, json, hashlib, unicodedata

def esc(s):
    return (s.replace("\\\\","\\\\\\\\")
             .replace("\\"","\\\\\\"")
             .replace("\\n","\\\\n")
             .replace("\\r","\\\\r")
             .replace("\\t","\\\\t"))

def cjson(obj):
    if isinstance(obj, dict):
        return "{" + ",".join(f"\\"{esc(k)}\\":{cjson(v)}" for k,v in sorted(obj.items())) + "}"
    if isinstance(obj, str):
        return f"\\"{esc(unicodedata.normalize("NFC",obj))}\\""
    if isinstance(obj, bool):
        return "true" if obj else "false"
    if isinstance(obj, int):
        return str(obj)
    return json.dumps(obj)

seq, ts, auth, etype, payload, prev = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
record = {
    "authority_source": auth,
    "entity_type": etype,
    "payload": payload,
    "prev_hash": prev,
    "sequence": int(seq),
    "timestamp": ts,
}
canonical = cjson(record)
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
'

GENESIS_PREV="0000000000000000000000000000000000000000000000000000000000000000"

echo "Verifying hash chain in: $VAULT"

# Extract rows ordered by sequence
ROWS=$(sqlite3 "$VAULT" \
    "SELECT sequence, timestamp, authority_source, entity_type, payload, prev_hash, hash \
     FROM vault_entries ORDER BY sequence ASC;" \
    2>/dev/null) || {
    echo "Error: failed to query vault (is it a valid MemoriaIA SQLite database?)" >&2
    exit 2
}

if [[ -z "$ROWS" ]]; then
    echo "Vault is empty — nothing to verify."
    exit 0
fi

TOTAL=$(echo "$ROWS" | wc -l | tr -d ' ')
IDX=0
VALID=1
PREV_STORED_HASH="$GENESIS_PREV"

while IFS='|' read -r seq ts auth etype payload prev stored_hash; do
    IDX=$((IDX + 1))
    PREFIX="  [$IDX/$TOTAL] seq=$seq"

    # Compute hash via Python
    COMPUTED=$(python - "$seq" "$ts" "$auth" "$etype" "$payload" "$prev" <<< "$HASH_FN") || {
        echo "$PREFIX  ✗ ERROR computing hash" >&2
        VALID=0
        continue
    }

    # Check stored hash matches computed hash
    HASH_OK=1
    if [[ "$stored_hash" != "$COMPUTED" ]]; then
        HASH_OK=0
        VALID=0
        echo "$PREFIX  ✗ HASH MISMATCH"
        echo "    stored:   $stored_hash"
        echo "    computed: $COMPUTED"
    fi

    # Check prev_hash linkage
    LINK_OK=1
    if [[ "$seq" == "1" ]]; then
        EXPECTED_PREV="$GENESIS_PREV"
    else
        EXPECTED_PREV="$PREV_STORED_HASH"
    fi

    if [[ "$prev" != "$EXPECTED_PREV" ]]; then
        LINK_OK=0
        VALID=0
        echo "$PREFIX  ✗ PREV_HASH LINK BROKEN"
        echo "    expected: $EXPECTED_PREV"
        echo "    stored:   $prev"
    fi

    if [[ "$HASH_OK" == "1" && "$LINK_OK" == "1" ]]; then
        if [[ "$seq" == "1" ]]; then
            echo "$PREFIX  ✓ hash OK  genesis"
        else
            echo "$PREFIX  ✓ hash OK  prev_hash link OK"
        fi
    fi

    PREV_STORED_HASH="$stored_hash"
done <<< "$ROWS"

echo ""
if [[ "$VALID" == "1" ]]; then
    echo "Chain VALID — $TOTAL record(s) verified."
    exit 0
else
    echo "Chain INVALID — tampering or corruption detected."
    exit 1
fi

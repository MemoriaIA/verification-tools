#!/usr/bin/env python3
"""
verify-hashchain.py — Independent hash-chain verifier for MemoriaIA vaults.

Usage:
    python verify-hashchain.py --vault path/to/vault.sqlite
    python verify-hashchain.py --vault path/to/vault.sqlite --verbose

This script requires only the Python standard library (no dependencies).

Verification model:
    Each record's hash is computed over a deterministic local canonical JSON
    representation of six fields: sequence, timestamp, authority_source,
    entity_type, payload, and prev_hash.

    The `payload` field is the encrypted ciphertext as stored in the vault.
    No decryption key is required. The verifier confirms chain integrity
    without ever reading the plaintext content of any record.

    The genesis record (sequence=1) must have prev_hash of 64 zero characters.
    Every subsequent record must have prev_hash equal to the stored hash of
    the previous record.

Exit codes:
    0 — chain is valid
    1 — chain is invalid (tampering or corruption detected)
    2 — usage error or vault cannot be opened
"""

import argparse
import hashlib
import json
import sqlite3
import sys
import unicodedata


GENESIS_PREV_HASH = "0" * 64
EXPECTED_PREV_HASH_FOR_SEQ1 = GENESIS_PREV_HASH
LOWER_HEX64 = set("0123456789abcdef")


def is_lower_hex64(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in LOWER_HEX64 for c in value)


def canonical_json(obj) -> str:
    """
    Serialize obj to deterministic local canonical JSON:
    - Object keys sorted alphabetically at all levels
    - No extra whitespace
    - NFC Unicode normalization on all string values
    - UTF-8 encoding assumed for the final output
    """
    if isinstance(obj, dict):
        return (
            "{"
            + ",".join(
                f'"{_escape(k)}":{canonical_json(v)}'
                for k, v in sorted(obj.items())
            )
            + "}"
        )
    if isinstance(obj, str):
        return json.dumps(
            unicodedata.normalize("NFC", obj),
            ensure_ascii=False,
            separators=(",", ":"),
        )
    if isinstance(obj, bool):
        return "true" if obj else "false"
    if isinstance(obj, int):
        return str(obj)
    if isinstance(obj, float):
        return json.dumps(obj)
    if obj is None:
        return "null"
    if isinstance(obj, list):
        return "[" + ",".join(canonical_json(i) for i in obj) + "]"
    raise TypeError(f"Cannot canonicalize type: {type(obj)}")


def _escape(s: str) -> str:
    """JSON-escape an object key after NFC normalization."""
    return json.dumps(
        unicodedata.normalize("NFC", s),
        ensure_ascii=False,
        separators=(",", ":"),
    )[1:-1]


def compute_record_hash(row: dict) -> str:
    """
    Compute SHA-256 over the canonical JSON of the six hashable fields.

    Fields included (in alphabetical order after canonicalization):
        authority_source, entity_type, payload, prev_hash, sequence, timestamp

    Fields excluded:
        id, hash (circular)
    """
    hashable = {
        "authority_source": row["authority_source"],
        "entity_type": row["entity_type"],
        "payload": row["payload"],
        "prev_hash": row["prev_hash"],
        "sequence": row["sequence"],
        "timestamp": row["timestamp"],
    }
    canonical = canonical_json(hashable)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def verify_vault(vault_path: str, verbose: bool = False) -> bool:
    """
    Open vault_path, read all vault_entries in sequence order, and verify:
      1. Each record's stored hash matches the computed hash.
      2. Each record's prev_hash matches the stored hash of the previous record.
      3. The genesis record (sequence=1) has prev_hash of 64 zero characters.

    Returns True if the chain is valid, False otherwise.
    """
    # Open AND read under one guard. sqlite3.connect(..., mode=ro) opens
    # lazily, so a corrupt/non-SQLite file or a missing vault_entries table does
    # not fail until the query runs. Both are environment errors ("vault cannot
    # be opened/read") and must exit 2 — never exit 1, which means "chain
    # invalid" and would mislabel an unreadable file as tampering.
    try:
        conn = sqlite3.connect(f"file:{vault_path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute(
            "SELECT id, sequence, timestamp, authority_source, entity_type, "
            "       payload, prev_hash, hash "
            "FROM vault_entries "
            "ORDER BY sequence ASC"
        )
        rows = cursor.fetchall()
        conn.close()
    except sqlite3.Error as e:
        print(f"Error: cannot read vault: {e}", file=sys.stderr)
        sys.exit(2)

    if not rows:
        print("Vault is empty — nothing to verify.")
        return True

    total = len(rows)
    print(f"Verifying hash chain in: {vault_path}")

    prev_stored_hash: str | None = None
    valid = True

    for i, row in enumerate(rows, start=1):
        seq = row["sequence"]
        stored_hash = row["hash"]
        computed_hash = compute_record_hash(dict(row))

        prefix = f"  [{i}/{total}] seq={seq}"

        sequence_ok = seq == i
        stored_hash_format_ok = is_lower_hex64(stored_hash)
        prev_hash_format_ok = is_lower_hex64(row["prev_hash"])

        # Check 1: stored hash matches computed hash
        hash_ok = stored_hash == computed_hash

        # Check 2: prev_hash linkage
        if seq == 1:
            expected_prev = GENESIS_PREV_HASH
        else:
            expected_prev = prev_stored_hash

        link_ok = row["prev_hash"] == expected_prev

        if hash_ok and link_ok and sequence_ok and stored_hash_format_ok and prev_hash_format_ok:
            if verbose:
                print(f"{prefix}  hash={stored_hash[:16]}...  ✓ OK")
            else:
                status = "✓ hash OK" + ("  prev_hash link OK" if seq > 1 else "  genesis")
                print(f"{prefix}  {status}")
        else:
            valid = False
            if not sequence_ok:
                print(f"{prefix}  ✗ SEQUENCE GAP OR REORDERING")
                print(f"    expected sequence: {i}")
                print(f"    stored sequence:   {seq}")
            if not stored_hash_format_ok:
                print(f"{prefix}  ✗ STORED HASH FORMAT INVALID")
                print(f"    stored:   {stored_hash}")
            if not prev_hash_format_ok:
                print(f"{prefix}  ✗ PREV_HASH FORMAT INVALID")
                print(f"    stored:   {row['prev_hash']}")
            if not hash_ok:
                print(f"{prefix}  ✗ HASH MISMATCH")
                print(f"    stored:   {stored_hash}")
                print(f"    computed: {computed_hash}")
            if not link_ok:
                print(f"{prefix}  ✗ PREV_HASH LINK BROKEN")
                print(f"    expected: {expected_prev}")
                print(f"    stored:   {row['prev_hash']}")

        prev_stored_hash = stored_hash

    if valid:
        print(f"\nChain VALID — {total} record{'s' if total != 1 else ''} verified.")
    else:
        print(f"\nChain INVALID — tampering or corruption detected.")

    return valid


def main() -> None:
    # Console-encoding hardening (Windows cp1252 and other legacy code pages).
    # The status lines below print U+2713 / U+2717 (checkmark / ballot-X). On a
    # cp1252 console these raise UnicodeEncodeError mid-run, which — left
    # unhandled — terminates the process with exit code 1, indistinguishable
    # from a genuine "chain invalid" result. Reconfiguring stdout to UTF-8 makes
    # those characters encodable; the try/except around verify_vault() below is
    # a belt-and-suspenders guarantee that a display failure can never be
    # reported as exit 1 (see the exit-code contract in this module's docstring).
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError, OSError):
        pass  # Older/replaced stdout: fall through to the guard below.

    parser = argparse.ArgumentParser(
        description="Independent hash-chain verifier for MemoriaIA vaults."
    )
    parser.add_argument(
        "--vault",
        required=True,
        metavar="PATH",
        help="Path to the SQLite vault file.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print truncated hashes for each record.",
    )
    args = parser.parse_args()

    try:
        ok = verify_vault(args.vault, verbose=args.verbose)
    except UnicodeEncodeError:
        # A console that cannot render the verifier's output is an environment
        # problem, not a statement about chain validity. It must never collide
        # with exit 1 ("chain invalid"); surface it as exit 2 (environment error).
        sys.stderr.write(
            "Error: console encoding could not render verifier output. "
            "Re-run with PYTHONIOENCODING=utf-8.\n"
        )
        sys.exit(2)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

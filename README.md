# MemoriaIA Verification Tools

Independent cryptographic verification for MemoriaIA vault integrity.

> **Engineering in progress.** MemoriaIA is under active development. The architecture is real, the cryptography is real — but the product is not yet ready for public release. We ship when the engineering is complete, not before. Follow progress at [alekore.ai](https://alekore.ai).

These tools allow any third party to verify the internal hash-chain consistency of a supplied MemoriaIA vault snapshot — that each record's stored hash matches the canonical representation of its fields, and that each record's `prev_hash` equals the hash of the preceding record — without any decryption key, without vendor cooperation, and without access to any proprietary product code. Interior deletion, insertion, reordering, and modification of records are all detectable this way. See [Known Limitations](#known-limitations) for what a single-snapshot hash chain cannot prove (notably tail truncation).

**The product is proprietary. The proof is public.**

---

## What This Repository Proves

| Claim | Enforcement | Verification |
|---|---|---|
| Records are append-only | SQL triggers block UPDATE and DELETE at the database level | Inspect `schema/append-only-triggers.sql` |
| Records form an unbroken hash chain | Each record commits to the SHA-256 hash of its predecessor | Run `verify/verify-hashchain.py` or `verify/verify-hashchain.sh` |
| Hash inputs are deterministic | Canonical JSON (RFC 8785 / JCS) with fixed field order | See Mathematical Specification below |
| Verification requires no decryption | Hashes are computed over the stored (encrypted) payload string | See Verification Model below |

---

## Known Limitations

**Tail truncation is not detectable.** Tail truncation (removal of the newest records) is not detectable without an external anchor such as a signed head hash or published expected record count. These tools do not yet include such an anchor. A verifier is handed a single SQLite snapshot and can only prove that snapshot is internally consistent; it has no independent reference for how many records *should* exist. A vault whose most recent entries have been removed — but whose remaining records still form an unbroken chain — will verify as `VALID` with exit code `0`.

What *is* detected: modification, insertion, reordering, and interior deletion of records all break either a stored hash or the `prev_hash` linkage and are reported as invalid. Only removal of records from the **end** of the chain escapes detection.

**Future architecture (not implemented).** A later version may bind the chain to an externally anchored head commitment — for example an Ed25519-signed head hash or a published expected record count — which would close the truncation gap. This is documented as planned direction only. No such anchor is implemented in these tools today, and the claims in this repository must be read accordingly.

---

## What This Repository Does NOT Contain

This repository is a **public proof surface**, not a product repository.

The following are explicitly excluded and will never appear here:

- UI, React, or frontend code
- Product services layer
- Data access layer (DAL)
- StateGuard implementation details
- License verification logic
- Ed25519 token parsing
- Encryption key material or key derivation
- Governance or internal policy documents
- CI/CD or pre-flight scripts
- Product configuration
- Private repository history

---

## Verification Model

These tools verify the SHA-256 chain over the canonical record payloads as stored in the MemoriaIA vault.
Verification is performed directly against the persisted record representation in the SQLite vault file.
No decryption key, no vendor cooperation, and no proprietary product code are required.

The `payload` field in the vault stores the encrypted representation of the memory record as it was written by the product. The hash chain is constructed over this **encrypted string as stored** — not over any decrypted plaintext. This means:

- A verifier with only the vault file can confirm chain integrity end-to-end.
- A verifier without the decryption key can still detect modification, insertion, interior deletion, or reordering of records. (Tail truncation is a documented exception — see [Known Limitations](#known-limitations).)
- The encrypted payload content remains private; only its integrity is proven.

---

## Mathematical Specification

For each record, the verification payload is constructed from these exact fields:

- `sequence`
- `timestamp`
- `authority_source`
- `entity_type`
- `payload`
- `prev_hash`

Rules:

- `id` is excluded from the hash
- Keys must be canonicalized using RFC 8785 (JCS)
- Alphabetical key order at all levels
- Compact JSON only (no extra whitespace)
- NFC Unicode normalization applied to all string values
- UTF-8 byte encoding
- SHA-256 output encoded as lowercase hexadecimal (64 characters)

The canonical hashable object is:

```json
{"authority_source":"<string>","entity_type":"<string>","payload":"<string>","prev_hash":"<string>","sequence":<number>,"timestamp":"<ISO8601>"}
```

The genesis record uses a `prev_hash` of 64 zero characters:

```
0000000000000000000000000000000000000000000000000000000000000000
```

**Important:** The `payload` field is the encrypted ciphertext string as stored in the vault column — not any decrypted value. Verification does not require knowledge of what the payload contains.

---

## Quick Start

### Prerequisites

**Python verification:**

No installation required — uses the Python standard library only.

**Bash verification:**
```bash
# Requires: sqlite3, python (for sha256sum with canonical JSON), or openssl
# See verify/verify-hashchain.sh for full requirements comment
```

### Python verification

```bash
python verify/verify-hashchain.py --vault path/to/vault.sqlite
```

Example output on a valid chain:

```
Verifying hash chain in: vault.sqlite
  [1/3] seq=1  ✓ hash OK
  [2/3] seq=2  ✓ hash OK  prev_hash link OK
  [3/3] seq=3  ✓ hash OK  prev_hash link OK
Chain VALID — 3 records verified.
```

Example output on a tampered vault:

```
  [2/3] seq=2  ✗ HASH MISMATCH
    stored:   77d3e0a8b0e6e47801b0ba6ce27382d6...
    computed: 4f2a91c0d8e7b3f1a6c5d2e9b8a7f0e3...
Chain INVALID — tampering or corruption detected at sequence 2.
```

### Bash verification

```bash
bash verify/verify-hashchain.sh path/to/vault.sqlite
```

### Example fixture

Load and verify the bundled example:

```bash
sqlite3 /tmp/example-vault.sqlite < fixtures/example-vault.sql
python verify/verify-hashchain.py --vault /tmp/example-vault.sqlite
```

Expected output: chain valid, 3 records.

---

## Append-Only Enforcement

`schema/append-only-triggers.sql` defines two SQLite triggers on the `vault_entries` table:

- **`prevent_vault_update`** — raises an error if any UPDATE is attempted on an existing row.
- **`prevent_vault_delete`** — raises an error if any DELETE is attempted on an existing row.

These triggers operate at the SQLite engine level. They do not depend on application-layer enforcement. Any client with direct database access that attempts to modify or remove a record will receive an error before the operation is committed.

The triggers alone do not prevent a sufficiently privileged actor from dropping and re-creating the table. The hash chain provides the second layer: even if triggers were removed, any alteration of the historical record would produce a detectable hash mismatch.

---

## Compatibility

| Component | Requirement |
|---|---|
| Database | SQLite 3.x |
| Python verifier | Python 3.8+ (standard library only) |
| Bash verifier | bash, sqlite3 CLI, openssl or sha256sum |
| Schema | Documented in `schema/vault-schema.sql` |

---

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability disclosure policy and scope.

---

## About Alekore

MemoriaIA is built by [Alekore](https://alekore.ai). Alekore builds tools for memory, trust, and personal data sovereignty.

This repository is maintained as a public accountability surface for the cryptographic integrity claims made by the MemoriaIA product.

---

## License

MIT — see [LICENSE](LICENSE).

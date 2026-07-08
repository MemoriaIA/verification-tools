# MemoriaIA Verification Tools

Independent cryptographic verification for MemoriaIA vault integrity.

> **Engineering in progress.** MemoriaIA is under active development. The architecture is real, the cryptography is real — but the product is not yet ready for public release. We ship when the engineering is complete, not before. Follow progress at [alekore.ai](https://alekore.ai).

These tools allow any third party to verify the internal hash-chain consistency of a supplied MemoriaIA vault snapshot — that each record's stored hash matches the canonical representation of its fields, and that each record's `prev_hash` equals the hash of the preceding record — without any decryption key, without vendor cooperation, and without access to any proprietary product code. They detect inconsistencies inside the supplied snapshot, such as non-recomputed edits, broken links, partial rewrites, and malformed stored hashes. They do not prove historical completeness or prove that a sufficiently privileged actor did not rebuild a different self-consistent snapshot. See [Known Limitations](#known-limitations).

**The product is proprietary. The proof is public.**

---

## What This Repository Proves

| Claim | Enforcement | Verification |
|---|---|---|
| Append-only trigger definitions are public | SQL trigger definitions block UPDATE and DELETE when installed in a live database | Inspect `memoriaia/schema/append-only-triggers.sql` |
| The supplied snapshot forms an internally consistent hash chain | Each record commits to the SHA-256 hash of its predecessor, and sequence numbers must be contiguous from 1 | Run `memoriaia/verify/verify-hashchain.py` or the compatibility wrapper `verify/verify-hashchain.sh` |
| Hash inputs are deterministic for the documented field set | Local canonical JSON with fixed field order and JSON string escaping | See Mathematical Specification below |
| Verification requires no decryption | Hashes are computed over the stored (encrypted) payload string | See Verification Model below |

---

## Known Limitations

**Completeness and historical rewrite are not detectable from a lone snapshot.** Tail truncation (removal of the newest records) is not detectable without an external anchor such as a signed head hash or published expected record count. These tools do not yet include such an anchor. A verifier is handed a single SQLite snapshot and can only prove that snapshot is internally consistent; it has no independent reference for how many records *should* exist.

The same boundary applies to a sufficiently privileged actor who can rewrite the snapshot and recompute the affected hashes. A vault whose newest entries were removed, or whose history was rewritten and rehashed into a new self-consistent chain, will verify as `VALID` with exit code `0`. What *is* detected: non-recomputed edits, broken `prev_hash` links, sequence gaps, partial rewrites, malformed stored hashes, and other inconsistencies inside the exact file being verified.

**Campaign status (under CEO_GO_VTOOLS_RELEASE_READINESS_FULL_CAMPAIGN_NO_RELEASE_01):**
Work is underway to implement signed manifest binding and external anchor models. See `docs/release-readiness.md` in this repo for the current design packet.

The repository now includes a bounded signed-manifest verifier with test-only fixture material and fail-closed checks. Production signing and anchor publication are out of scope for this campaign. All claims remain strictly bounded per the design packet and the CEO token.

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

These tools verify the SHA-256 chain over the canonical record payloads as stored in the supplied MemoriaIA vault snapshot.
Verification is performed directly against the persisted record representation in the SQLite vault file.
No decryption key, no vendor cooperation, and no proprietary product code are required.

The `payload` field in the vault stores the encrypted representation of the memory record as it was written by the product. The hash chain is constructed over this **encrypted string as stored** — not over any decrypted plaintext. This means:

- A verifier with only the vault file can confirm internal chain consistency for that file.
- A verifier without the decryption key can still detect non-recomputed modification, insertion, row removal, or reordering when those changes leave inconsistent hashes, links, or sequence gaps. Completeness and fully recomputed rewrites are documented exceptions — see [Known Limitations](#known-limitations).
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
- Keys are serialized in deterministic alphabetical order for the documented field set
- Alphabetical key order at all levels
- Compact JSON only (no extra whitespace)
- NFC Unicode normalization applied to all string values
- JSON string escaping for control characters, quotes, and backslashes
- UTF-8 byte encoding
- SHA-256 output encoded as lowercase hexadecimal (64 characters)
- `sequence` values must be contiguous from 1 through the number of rows returned by the snapshot query

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

> **Repository layout (migration note).** All verification assets — schema, fixtures, and verifiers — now live under the `memoriaia/` directory. Earlier revisions kept them at the repository root (`verify/`, `schema/`, `fixtures/`); update any saved paths to the `memoriaia/` prefix. The verifier interface is unchanged — each script still takes the vault path via `--vault` (Python) or as its first argument (bash), so only the location of the scripts moved, not how you call them.

### Prerequisites

**Python verification:**

No installation required — uses the Python standard library only.

**Bash verification:**
```bash
# Requires: bash and python 3.8+ (standard library only).
# The bash verifier delegates SQLite reading, canonical JSON, and SHA-256 hashing to python.
# See verify/verify-hashchain.sh for the shell compatibility wrapper.
```

### Python verification

```bash
python memoriaia/verify/verify-hashchain.py --vault path/to/vault.sqlite
```

Example output on a valid chain:

```
Verifying hash chain in: vault.sqlite
  [1/3] seq=1  ✓ hash OK  genesis
  [2/3] seq=2  ✓ hash OK  prev_hash link OK
  [3/3] seq=3  ✓ hash OK  prev_hash link OK

Chain VALID — 3 records verified.
```

Example output on a tampered vault:

```
  [2/3] seq=2  ✗ HASH MISMATCH
    stored:   77d3e0a8b0e6e47801b0ba6ce27382d6...
    computed: 4f2a91c0d8e7b3f1a6c5d2e9b8a7f0e3...

Chain INVALID — tampering or corruption detected.
```

(The bash verifier is a shell wrapper around the same Python verification implementation, so it reports the same verdicts, output, and exit codes.)

### Bash verification

```bash
bash verify/verify-hashchain.sh path/to/vault.sqlite
```

### Signed manifest verification

The repository also includes a test-only release-candidate manifest verifier:

```bash
bash verify/verify-release-manifest.sh \
  --manifest release/fixtures/example-release-manifest.json \
  --signature release/fixtures/example-release-manifest.sig \
  --public-key release/test-public-key.pub
```

The fixture demonstrates detached signature verification, snapshot hashing, Git blob hash binding, and deterministic anchor-commitment recomputation. It uses test-only trust material and records that no external anchor has been published for the fixture.

### Example fixture

Load and verify the bundled example:

```bash
sqlite3 /tmp/example-vault.sqlite < memoriaia/fixtures/example-vault.sql
python memoriaia/verify/verify-hashchain.py --vault /tmp/example-vault.sqlite
```

Expected output: chain valid, 3 records.

---

## Append-Only Enforcement

`memoriaia/schema/append-only-triggers.sql` defines two SQLite triggers on the `vault_entries` table:

- **`prevent_vault_update`** — raises an error if any UPDATE is attempted on an existing row.
- **`prevent_vault_delete`** — raises an error if any DELETE is attempted on an existing row.

These triggers operate at the SQLite engine level. They do not depend on application-layer enforcement. Any client with direct database access that attempts to modify or remove a record will receive an error before the operation is committed.

The triggers alone do not prove they were installed historically, and this verifier does not check trigger presence. A sufficiently privileged actor can drop triggers, rewrite rows, and recompute a self-consistent chain. In that case the snapshot verifies as internally consistent unless an external anchor exists. The hash chain detects non-recomputed or partial alteration; it is not an authenticated history ledger by itself.

---

## Compatibility

| Component | Requirement |
|---|---|
| Database | SQLite 3.x |
| Python verifier | Python 3.8+ (standard library only) |
| Bash verifier | bash, sqlite3 CLI, python 3.8+ |
| Schema | Documented in `memoriaia/schema/vault-schema.sql` |

---

## Scope & Disclaimer

See [DISCLAIMER.md](DISCLAIMER.md) for a precise statement of what these tools prove — the internal hash-chain consistency of a supplied vault snapshot — and, just as importantly, what they do **not** prove (including the tail-truncation limitation described under [Known Limitations](#known-limitations)).

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

# Release-Readiness Design for verification-tools

**Token:** CEO_GO_VTOOLS_RELEASE_READINESS_FULL_CAMPAIGN_NO_RELEASE_01  
**Date:** 2026-07-08  
**Status:** Design baseline (to be iterated in campaign)  
**Scope:** This document defines the models for moving verification-tools to Release Candidate readiness. It does **not** authorize any release, tag, signing, or public claims.

## 1. What a release artifact is
A release artifact is a versioned, signed, reproducible package containing:
- The verifier script(s) (Python + bash shim) at a pinned commit.
- The public schema and triggers.
- Example fixtures.
- A signed manifest (see below).
- Checksum file.
- Instructions for offline verification.

Release artifacts are distributed via GitHub releases (or equivalent) but **no actual GitHub release is created** under this token.

## 2. What the verifier verifies and does not verify
**Verifies (internal consistency of supplied snapshot):**
- Each record's stored `hash` matches recomputed SHA-256 over canonical fields.
- `prev_hash` linkage.
- Contiguous sequence from 1.
- Format of hashes (lowercase hex-64).

**Does NOT verify (unless anchored/manifest-bound):**
- Historical completeness (tail truncation undetectable without anchor).
- That the snapshot was the one produced by the legitimate writer at the time.
- That append-only triggers were active historically.
- Content truth or decryption.
- That the snapshot file itself was not substituted (addressed by signed manifest + anchor).

## 3. Signed snapshot manifest model
The manifest is a JSON document that cryptographically binds the snapshot to the verifier, schema, and repo state.

Required fields (minimum):
- `manifest_version`: "1.0"
- `snapshot`: { "path_hint": "...", "sha256": "<hash of vault file or head record + count>" }
- `schema_sha256`: hash of vault-schema.sql + append-only-triggers.sql
- `verifier_sha256`: hash of the exact verify-hashchain.py used
- `repo_commit`: the git SHA at which the verifier was built
- `record_count`: integer
- `head_sequence`: integer
- `head_hash`: the last record's stored hash
- `timestamp`: ISO8601 issuance
- `claim_boundary`: reference to disclaimer or section in this design
- `verification_command`: exact command to run for verification
- `signature`: Ed25519 signature over the canonical manifest (excluding signature field)

Verification must fail closed if any binding does not match or signature fails.

**Test/demo keys only** in this campaign. Production key custody is a separate Founder decision.

## 4. External anchor / head commitment model
An external anchor is a signed commitment to (head_hash, record_count, timestamp) published in an immutable or high-trust location (GitHub release asset, transparency log stub, or separate ledger).

- Must be verifiable independently of the snapshot.
- Release mode must require a valid anchor for "historical" claims.
- Without anchor: verifier reports "internal consistency only".
- The model must explicitly fail or warn when anchor is absent if stronger claims are requested.

First implementation may be file-based signed anchor + manifest for the RC.

## 5. Verifier bootstrap / provenance preparation
- Every release artifact must include:
  - `verifier.sha256`
  - `manifest.json` (signed)
  - `RELEASE-READINESS.md` (this or successor)
  - Offline verification instructions
- Build/repro instructions must be present.
- Reproducibility: note current limitations (Python stdlib helps, but full bit-for-bit requires pinned env).
- No SLSA claim until mechanically supported.

## 6. Release/tag/provenance strategy
- Tags and GitHub releases are **forbidden** under this token.
- Provenance is prepared via the signed manifest + anchor + checksums.
- Future releases will use the models defined here.
- All claims must be bounded in the artifact docs.

## 7. Key custody assumptions and Founder-controlled signing boundary
- Verifier signing key(s) must be Founder-controlled.
- No production private keys in this repo or any campaign artifact.
- Test keys must be clearly named `test-only-*.pem` or equivalent and rejected by any "production" verification path.
- Signature verification must support multiple keys (rotation) and fail closed on missing/invalid sig.

## 8. Exact claims authorized after implementation (example)
- "The supplied snapshot is internally consistent with the committed verifier and schema at commit X."
- "A signed manifest binds the snapshot to the above."
- "When an external anchor is present and verified, tail truncation and some rewrite classes become detectable."

## 9. Exact claims still forbidden
- Any claim of historical completeness without a verified anchor.
- "Tamper-proof history" or "append-only proof" without anchor.
- "CISO-ready", "NASA-grade", "SLSA L3", "public release ready", "zero debt", "global clean close".
- That the verifier proves the content was written by the claimed authority without additional evidence.
- That a snapshot without manifest/anchor is equivalent to one with them.

---

**Next steps in campaign (per token):**
- Implement bounded signed manifest (PHASE 2).
- Implement anchor model (PHASE 3).
- Add bootstrap artifacts and instructions (PHASE 4).
- Harden docs (PHASE 5).
- Run internal swarm + external 3-provider quorum (PHASE 6/7).
- Produce Release Candidate Packet.

All work under this token must stop at any hard stop listed in the CEO order.

This design will be updated as the campaign iterates. Changes must be reviewed against the token scope.
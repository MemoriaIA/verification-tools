# Release-Readiness Design Packet

Token: `CEO_GO_VTOOLS_RELEASE_READINESS_FULL_CAMPAIGN_NO_RELEASE_01`

Status: campaign design and verification surface. This document does not publish a release, create a tag, deploy, sign with production keys, publish a package, or authorize public assurance claims.

## Artifact Definition

A future release artifact is expected to be a source snapshot or packaged verification-tools bundle plus a signed release-candidate manifest. The artifact set is expected to include:

- verifier scripts at a pinned commit;
- public schema and append-only trigger SQL;
- example fixtures;
- a signed manifest;
- checksum material;
- offline verification instructions.

No release artifact is created by this design packet.

## What the Hash-Chain Verifier Checks

The hash-chain verifier checks internal consistency of a supplied SQLite vault snapshot:

- each stored `hash` matches recomputation over canonical fields;
- each `prev_hash` links to the previous stored hash;
- sequence values are contiguous from 1;
- stored hashes are lowercase 64-hex values.

## What the Hash-Chain Verifier Does Not Check

The verifier does not prove historical completeness, does not prove that append-only triggers were installed historically, does not prove content truth, and does not protect against a fully recomputed self-consistent rewrite unless an independently published external anchor is available and checked.

Without an anchor, the truthful result remains internal consistency of the supplied snapshot only.

## Signed Manifest Model

The manifest is a JSON document that binds a snapshot to verifier materials and claim boundaries. The implemented verifier checks:

- manifest version and type;
- repository identity;
- detached RSA/SHA-256 signature over the exact manifest bytes;
- snapshot SHA-256 over bytes on disk;
- selected Git blob hashes for schema, verifier, and disclaimer files;
- deterministic anchor commitment recomputation;
- explicit claim-boundary flags.

The committed fixture uses `profile: test-only-fixture`. The verifier has a `--release-mode` switch that fails closed for this fixture because no external anchor reference is published.

## External Anchor Model

The manifest includes a `head-commitment-v1` value. The commitment preimage is deterministic and includes:

- repository identity;
- manifest profile;
- repository commit reference;
- snapshot SHA-256;
- schema SHA-256;
- verifier SHA-256;
- disclaimer SHA-256.

A later release process may publish this commitment outside the mutable repository history. Until then, the fixture records `not_published_test_fixture`, and stronger history claims remain unavailable.

## Bootstrap and Provenance Preparation

Bootstrap trust requires:

- an independently obtained public key;
- a detached manifest signature;
- a concrete repository commit for the release candidate;
- an external anchor reference for history-sensitive claims;
- offline verification instructions.

The repository prepares these mechanics, but it does not establish production key custody or release provenance by itself.

## Key Custody

Production signing keys remain Founder-controlled and are not generated or stored in this repository. The committed public key is test-only fixture material. The test private key used to sign the fixture was temporary local material and is not committed.

## Current Test Fixture

The fixture files are:

- `release/fixtures/example-release-manifest.json`
- `release/fixtures/example-release-manifest.sig`
- `release/test-public-key.pub`

The verification command is:

```bash
bash verify/verify-release-manifest.sh \
  --manifest release/fixtures/example-release-manifest.json \
  --signature release/fixtures/example-release-manifest.sig \
  --public-key release/test-public-key.pub
```

Negative gates assert that modified manifest bytes, bad signatures, private-key material in the public-key slot, and release mode without an external anchor all fail closed.

## Maximum Claim After This Packet

If all gates and audits pass, the maximum claim is that a release-candidate packet is ready for CEO review. Public release, assurance-grade, provenance, package, deployment, and formal approval claims remain forbidden until separately authorized and mechanically proven.

## Explicit 9-Point Design Coverage

1. What a release artifact is — See "Artifact Definition" above.
2. What the verifier verifies and does not verify — See dedicated sections above.
3. Signed snapshot manifest model — See "Signed Manifest Model".
4. External anchor / head commitment model — See "External Anchor Model" + head-commitment-v1.
5. Verifier bootstrap trust model — See "Bootstrap and Provenance Preparation".
6. Release/tag/provenance strategy — See "Production Boundary" and this document (no actual release performed).
7. Key custody assumptions and Founder-controlled signing boundary — See "Key Custody".
8. Exact claims authorized after implementation — See "Maximum Claim After This Packet".
9. Exact claims still forbidden — See claim_boundary flags and "no_public_release_claim".

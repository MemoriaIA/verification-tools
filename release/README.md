# Release-Candidate Manifest Model

This directory contains a test-only manifest fixture and verification notes for a future verification-tools release process. It is not a published release, tag, package, deployment, signed product artifact, or production key-custody record.

## Model

A release-candidate manifest binds:

- a supplied snapshot hash;
- selected verifier and schema Git blob hashes;
- the repository identity;
- manifest version and issuance metadata;
- a detached signature over the exact manifest bytes;
- an anchor commitment preimage that can be published outside the repository in a later release process.

The fixture in `release/fixtures/example-release-manifest.json` uses `profile: test-only-fixture`. It is present so the verifier has deterministic positive and negative tests. It does not create an external anchor and does not prove historical completeness.

## Production Boundary

Production release signing remains Founder-controlled and is not implemented here. This repository must not contain production private keys. A production release-candidate manifest would use `profile: release-candidate`, a concrete commit SHA, structured externally published anchor metadata, and a public key whose expected SHA-256 is supplied from an authority outside the manifest.

## Verification Boundary

The manifest verifier can confirm that the manifest signature, declared snapshot hash, tracked Git blob hashes, and anchor commitment are self-consistent. It cannot prove that a snapshot is complete over time unless the head commitment is independently anchored outside the mutable repository history.

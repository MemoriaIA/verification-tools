# Verifier Bootstrap & Provenance Instructions

**Token:** CEO_GO_VTOOLS_RELEASE_READINESS_FULL_CAMPAIGN_NO_RELEASE_01

This document provides the bootstrap steps for a release-candidate verification-tools bundle. It does **not** constitute a published release.

## Obtaining the Candidate
1. Checkout the exact commit recorded in the manifest (`repo_commit`).
2. Verify the working tree is clean: `git status --porcelain` must be empty.
3. Confirm the manifest and signature files are present.

## Verification Steps (offline capable)
```bash
# 1. Verify the release manifest (binds snapshot, tracked files, anchor preimage)
bash verify/verify-release-manifest.sh \
  --manifest release/fixtures/example-release-manifest.json \
  --signature release/fixtures/example-release-manifest.sig \
  --public-key release/test-public-key.pub

# 2. (When real anchor and trust root are published) Re-run with --release-mode
# The command must fail closed unless --expected-public-key-sha256 is supplied
# from an authority outside the manifest and external_publication is structured.

# 3. Verify the hash-chain on the supplied vault using the pinned verifier
python memoriaia/verify/verify-hashchain.py --vault <your-vault.sqlite>
```

## Reproducibility Notes
- Core verifier uses only Python stdlib + sqlite3 (no third-party dependencies for the hash-chain path).
- The release-manifest verifier currently depends on `openssl` for signature verification (common on supported platforms).
- Full bit-for-bit reproducibility requires a pinned environment (Python version, openssl version, git version). Current campaign does not claim SLSA level.

## Claim Boundaries (must be preserved in any derived material)
See claim_boundary in the manifest and the explicit 9-point section in docs/release-readiness.md.

Production key custody, real external anchor publication, and final CEO approval are separate decisions outside this repository.

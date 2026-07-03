# Disclaimer

**Scope of proof.** The tools in this repository verify one narrow technical property: the internal hash-chain consistency of a supplied SQLite vault snapshot. For each record they confirm that the stored hash matches the canonical representation of the record's fields, and that each record's `prev_hash` equals the hash of the preceding record. That is the whole of what they check.

**What these tools do NOT prove:**
- the truth, accuracy, completeness, or meaning of any stored or encrypted content;
- that a vault is complete — the newest records may have been removed (see the known limitation below);
- the correctness, safety, or fitness of any Alekore or MemoriaIA product;
- anything about a vault other than the internal consistency of the exact file the tool was run against, at the moment it was run.

**Known limitation.** Hash-chain verification detects modification, insertion, reordering, and interior deletion of records. Removal of records from the end of the chain (tail truncation) is not detectable without an externally anchored head commitment, which these tools do not yet include. A truncated but internally consistent vault verifies as valid.

These tools are provided under the repository's MIT License (see `LICENSE`). A verification result describes the file it was run against — nothing more.

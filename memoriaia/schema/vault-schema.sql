-- MemoriaIA Vault Schema
-- Public verification surface — curated for hash-chain auditing.
--
-- This file documents the schema of the `vault_entries` table as it exists
-- in the MemoriaIA SQLite vault. It contains only the columns and constraints
-- required to understand and independently verify the hash chain.
--
-- Excluded from this file:
--   - Application-layer indexes beyond those needed for verification
--   - Internal metadata tables
--   - Any schema elements not relevant to integrity proof

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- vault_entries: append-only ledger of all MemoriaIA memory events.
--
-- Each row represents one immutable record in the vault. Records are written
-- once and never modified or deleted (enforced by triggers; see
-- append-only-triggers.sql).
--
-- The hash chain links each record to its predecessor via SHA-256, computed
-- over a canonical JSON representation of the record fields listed below.
-- Verification does not require decrypting the payload field.

CREATE TABLE IF NOT EXISTS vault_entries (
    -- Internal row identifier. Excluded from hash computation.
    id               TEXT NOT NULL PRIMARY KEY,

    -- Monotonically increasing sequence number within this vault.
    -- Included in hash. The verifier requires sequences to be contiguous from
    -- 1 through the number of rows returned by the snapshot query.
    sequence         INTEGER NOT NULL UNIQUE CHECK (sequence >= 1),

    -- ISO 8601 timestamp of when the record was written.
    -- Included in hash.
    timestamp        TEXT NOT NULL,

    -- Identifies the actor that produced this record.
    -- Format: "system" for automated entries, "user.<ulid>" for user actions.
    -- Included in hash.
    authority_source TEXT NOT NULL,

    -- Semantic type of the memory event (e.g. "memory.created", "memory.tagged").
    -- Included in hash.
    entity_type      TEXT NOT NULL,

    -- The encrypted payload as stored. This is the ciphertext string persisted
    -- by the product. Verification is performed over this string as-is; no
    -- decryption is required or performed by the verification tools.
    -- Included in hash.
    payload          TEXT NOT NULL,

    -- SHA-256 hash of the previous record's canonical representation.
    -- For the genesis record (sequence = 1), this is 64 zero characters.
    -- Included in hash.
    prev_hash        TEXT NOT NULL CHECK (
        length(prev_hash) = 64
        AND prev_hash NOT GLOB '*[^0-9a-f]*'
    ),

    -- SHA-256 hash of this record's canonical representation (self-referential).
    -- Computed by the writer and stored for fast verification.
    -- NOT included in the hash input (would be circular).
    hash             TEXT NOT NULL CHECK (
        length(hash) = 64
        AND hash NOT GLOB '*[^0-9a-f]*'
    )
);

-- Verification order index. Supports sequential traversal without a full scan.
CREATE INDEX IF NOT EXISTS idx_vault_entries_sequence
    ON vault_entries (sequence ASC);

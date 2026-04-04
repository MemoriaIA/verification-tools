-- example-vault.sql — Example fixture for hash-chain verification testing.
--
-- This fixture contains three records forming a valid, verifiable hash chain.
-- All payloads are synthetic base64-encoded ciphertext strings that represent
-- what an encrypted payload looks like as stored in a real MemoriaIA vault.
--
-- No real user data is present. No decryption key is required or implied.
--
-- To load and verify:
--   sqlite3 /tmp/example-vault.sqlite < fixtures/example-vault.sql
--   python verify/verify-hashchain.py --vault /tmp/example-vault.sqlite
--
-- Expected result: Chain VALID — 3 records verified.
--
-- Verification of this fixture:
--   Record 1 canonical input:
--     {"authority_source":"system","entity_type":"memory.created","payload":"dGVzdC1jaXBoZXJ0ZXh0LXBheWxvYWQtMDEtYWFhYWFhYWFhYWFhYWFhYQ==","prev_hash":"0000000000000000000000000000000000000000000000000000000000000000","sequence":1,"timestamp":"2026-01-15T10:00:00.000Z"}
--     SHA-256: ae7d4551fa9b819bbbaa0805d6876bee96f062af8cdf36b55dae2d2b0f2c9e47
--
--   Record 2 canonical input:
--     {"authority_source":"user.01JQEXAMPLEUSER001","entity_type":"memory.updated","payload":"dGVzdC1jaXBoZXJ0ZXh0LXBheWxvYWQtMDItYmJiYmJiYmJiYmJiYmJiYg==","prev_hash":"ae7d4551fa9b819bbbaa0805d6876bee96f062af8cdf36b55dae2d2b0f2c9e47","sequence":2,"timestamp":"2026-01-15T10:05:23.417Z"}
--     SHA-256: 77d3e0a8b0e6e47801b0ba6ce27382d6e6a68191b6690d9a82fdfdf60db07a48
--
--   Record 3 canonical input:
--     {"authority_source":"user.01JQEXAMPLEUSER001","entity_type":"memory.tagged","payload":"dGVzdC1jaXBoZXJ0ZXh0LXBheWxvYWQtMDMtY2NjY2NjY2NjY2NjY2NjYw==","prev_hash":"77d3e0a8b0e6e47801b0ba6ce27382d6e6a68191b6690d9a82fdfdf60db07a48","sequence":3,"timestamp":"2026-01-15T10:12:47.882Z"}
--     SHA-256: 60ae3dcd7777c0729f522a4431b8e7ec9f0c1a48457c0c469441d45a464f2548

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS vault_entries (
    id               TEXT NOT NULL PRIMARY KEY,
    sequence         INTEGER NOT NULL UNIQUE CHECK (sequence >= 1),
    timestamp        TEXT NOT NULL,
    authority_source TEXT NOT NULL,
    entity_type      TEXT NOT NULL,
    payload          TEXT NOT NULL,
    prev_hash        TEXT NOT NULL CHECK (length(prev_hash) = 64),
    hash             TEXT NOT NULL CHECK (length(hash) = 64)
);

CREATE INDEX IF NOT EXISTS idx_vault_entries_sequence
    ON vault_entries (sequence ASC);

-- Append-only triggers
CREATE TRIGGER IF NOT EXISTS prevent_vault_update
    BEFORE UPDATE ON vault_entries
BEGIN
    SELECT RAISE(ABORT, 'vault_entries is append-only: UPDATE is not permitted');
END;

CREATE TRIGGER IF NOT EXISTS prevent_vault_delete
    BEFORE DELETE ON vault_entries
BEGIN
    SELECT RAISE(ABORT, 'vault_entries is append-only: DELETE is not permitted');
END;

-- Record 1 — genesis
INSERT INTO vault_entries (id, sequence, timestamp, authority_source, entity_type, payload, prev_hash, hash)
VALUES (
    '01JQEXAMPLERECORD001',
    1,
    '2026-01-15T10:00:00.000Z',
    'system',
    'memory.created',
    'dGVzdC1jaXBoZXJ0ZXh0LXBheWxvYWQtMDEtYWFhYWFhYWFhYWFhYWFhYQ==',
    '0000000000000000000000000000000000000000000000000000000000000000',
    'ae7d4551fa9b819bbbaa0805d6876bee96f062af8cdf36b55dae2d2b0f2c9e47'
);

-- Record 2
INSERT INTO vault_entries (id, sequence, timestamp, authority_source, entity_type, payload, prev_hash, hash)
VALUES (
    '01JQEXAMPLERECORD002',
    2,
    '2026-01-15T10:05:23.417Z',
    'user.01JQEXAMPLEUSER001',
    'memory.updated',
    'dGVzdC1jaXBoZXJ0ZXh0LXBheWxvYWQtMDItYmJiYmJiYmJiYmJiYmJiYg==',
    'ae7d4551fa9b819bbbaa0805d6876bee96f062af8cdf36b55dae2d2b0f2c9e47',
    '77d3e0a8b0e6e47801b0ba6ce27382d6e6a68191b6690d9a82fdfdf60db07a48'
);

-- Record 3
INSERT INTO vault_entries (id, sequence, timestamp, authority_source, entity_type, payload, prev_hash, hash)
VALUES (
    '01JQEXAMPLERECORD003',
    3,
    '2026-01-15T10:12:47.882Z',
    'user.01JQEXAMPLEUSER001',
    'memory.tagged',
    'dGVzdC1jaXBoZXJ0ZXh0LXBheWxvYWQtMDMtY2NjY2NjY2NjY2NjY2NjYw==',
    '77d3e0a8b0e6e47801b0ba6ce27382d6e6a68191b6690d9a82fdfdf60db07a48',
    '60ae3dcd7777c0729f522a4431b8e7ec9f0c1a48457c0c469441d45a464f2548'
);

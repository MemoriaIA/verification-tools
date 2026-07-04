-- Append-Only Enforcement Triggers
-- MemoriaIA vault — public verification surface.
--
-- These triggers prevent any modification or deletion of existing rows in
-- vault_entries. They operate at the SQLite engine level and are independent
-- of the application layer.
--
-- Two-layer integrity model:
--   Layer 1 (these triggers): block UPDATE/DELETE at the database engine.
--   Layer 2 (hash chain):     detect any tampering even if triggers are removed.
--
-- To verify triggers are installed on a vault:
--   sqlite3 vault.sqlite "SELECT name, sql FROM sqlite_master WHERE type='trigger';"

-- Prevent modification of any existing vault record.
CREATE TRIGGER IF NOT EXISTS prevent_vault_update
    BEFORE UPDATE ON vault_entries
BEGIN
    SELECT RAISE(
        ABORT,
        'vault_entries is append-only: UPDATE is not permitted'
    );
END;

-- Prevent deletion of any existing vault record.
CREATE TRIGGER IF NOT EXISTS prevent_vault_delete
    BEFORE DELETE ON vault_entries
BEGIN
    SELECT RAISE(
        ABORT,
        'vault_entries is append-only: DELETE is not permitted'
    );
END;

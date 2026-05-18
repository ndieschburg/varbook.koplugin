--[[
    Local SQLite storage for position tracking.
    Stores reading positions (percentage + timestamp) and tracks sync status.
]]--

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local VarbookDB = {}

local DB_PATH = DataStorage:getSettingsDir() .. "/varbook_positions.sqlite3"

-- Cleanup threshold: synced positions older than 30 days
local CLEANUP_MAX_AGE = 30 * 86400

function VarbookDB:open()
    if self.conn then
        return self.conn
    end
    self.conn = SQ3.open(DB_PATH)
    self:createTable()
    self:cleanup()
    return self.conn
end

function VarbookDB:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

function VarbookDB:createTable()
    self.conn:exec([[
        CREATE TABLE IF NOT EXISTS positions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_hash    TEXT NOT NULL,
            percentage  REAL NOT NULL,
            timestamp   INTEGER NOT NULL,
            synced      INTEGER DEFAULT 0,
            xpointer    TEXT
        );
    ]])
    self.conn:exec([[
        CREATE INDEX IF NOT EXISTS idx_positions_unsynced
        ON positions (doc_hash, synced);
    ]])
    -- Add xpointer column if upgrading from older schema
    self:migrateAddXpointer()
end

--- Add xpointer column to existing tables (safe to call multiple times).
function VarbookDB:migrateAddXpointer()
    local ok, err = pcall(function()
        self.conn:exec("ALTER TABLE positions ADD COLUMN xpointer TEXT;")
    end)
    if not ok and not err:find("duplicate column") then
        logger.warn("Varbook: xpointer migration error:", err)
    end
end

--- Remove old synced positions to save disk space.
function VarbookDB:cleanup()
    local cutoff = os.time() - CLEANUP_MAX_AGE
    self.conn:exec(string.format(
        "DELETE FROM positions WHERE synced = 1 AND timestamp < %d;",
        cutoff
    ))
end

--- Record a reading position.
-- @param doc_hash string KOReader partial MD5
-- @param percentage number Reading progress 0-100
-- @param xpointer string|nil XPointer position string
function VarbookDB:addPosition(doc_hash, percentage, xpointer)
    local conn = self:open()
    local stmt = conn:prepare([[
        INSERT INTO positions (doc_hash, percentage, timestamp, xpointer)
        VALUES (?, ?, ?, ?);
    ]])
    stmt:reset():bind(doc_hash, percentage, os.time(), xpointer):step()
    stmt:close()
end

--- Get all unsynced positions for a document.
-- @param doc_hash string KOReader partial MD5
-- @return table Array of {percentage, timestamp, xpointer} records
function VarbookDB:getUnsyncedPositions(doc_hash)
    local conn = self:open()
    local results = {}
    local stmt = conn:prepare([[
        SELECT percentage, timestamp, xpointer
        FROM positions
        WHERE doc_hash = ? AND synced = 0
        ORDER BY timestamp ASC;
    ]])
    stmt:reset():bind(doc_hash)
    while true do
        local row = stmt:step()
        if not row then break end
        table.insert(results, {
            percentage = tonumber(row[1]),
            timestamp = tonumber(row[2]),
            xpointer = row[3],
        })
    end
    stmt:close()
    return results
end

--- Count unsynced positions for a document (or all documents).
-- @param doc_hash string|nil Optional document hash filter
-- @return number Count of unsynced positions
function VarbookDB:countUnsynced(doc_hash)
    local conn = self:open()
    local result
    if doc_hash then
        local stmt = conn:prepare(
            "SELECT count(*) FROM positions WHERE doc_hash = ? AND synced = 0;"
        )
        result = stmt:reset():bind(doc_hash):step()
        stmt:close()
    else
        result = conn:rowexec(
            "SELECT count(*) FROM positions WHERE synced = 0;"
        )
        return tonumber(result)
    end
    return tonumber(result[1])
end

--- Mark all unsynced positions for a document as synced.
-- @param doc_hash string KOReader partial MD5
function VarbookDB:markSynced(doc_hash)
    local conn = self:open()
    local stmt = conn:prepare([[
        UPDATE positions SET synced = 1
        WHERE doc_hash = ? AND synced = 0;
    ]])
    stmt:reset():bind(doc_hash):step()
    stmt:close()
end

return VarbookDB

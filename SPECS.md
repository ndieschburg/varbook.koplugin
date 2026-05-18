# Varbook KOReader Plugin - Specification v1

## Overview

A KOReader plugin that synchronizes reading positions with the Varbook (BookShelf) server. Uses **percentages** as the universal progress format, with **xpointer** support for precise koreader-to-koreader navigation on reflowable documents. Falls back to percentage-based page navigation for cross-client sync (e.g. web reader).

## Scope (v1)

**In scope:**
- Manual sync via menu button ("Sync with Varbook")
- Page turn position tracking (accumulate percentages locally)
- Batch push of unsynced positions
- Pull server position and navigate via percentage if newer
- Book identification via koreader partial MD5 hash

**Out of scope (future):**
- Remote library browsing (use OPDS for now)
- Auto-sync on suspend/resume
- Book download management

## Architecture

```
┌──────────────────────┐         ┌──────────────────┐
│  KOReader Plugin      │         │  Varbook Server   │
│                       │         │                   │
│  onPageUpdate()       │         │                   │
│    ↓                  │         │                   │
│  SQLite (% + ts)      │         │                   │
│    ↓                  │  HTTP   │                   │
│  [Sync Button] ───────┼────────→│ POST batch (%)    │
│                       │←────────┼─ GET  progress (%)│
│  GotoPercentage(p)    │         │                   │
└──────────────────────┘         └──────────────────┘
```

## Plugin Structure

```
plugins/varbook.koplugin/
├── _meta.lua          # Plugin metadata
├── main.lua           # Entry point, WidgetContainer
├── varbook_api.lua    # HTTP client wrapper for Varbook API
└── varbook_db.lua     # SQLite storage for position queue
```

## Configuration

Stored via `LuaSettings` in KOReader's settings directory.

| Setting | Type | Description |
|---------|------|-------------|
| `server_url` | string | Varbook server base URL (e.g. `https://bookshelf.hophop.be`) |
| `token` | string | 16-char alphanumeric API token (entered manually) |

Configuration UI: menu entry "Varbook > Settings" with input dialogs for each field.

## Authentication

Simple token-based auth via HTTP header:

```
Authorization: Bearer <16-char-token>
```

### Plugin side
- User enters the token manually in plugin settings (copied from the Varbook web UI)
- Token stored in LuaSettings
- Sent as `Authorization: Bearer <token>` header on every API request

### Server side (Varbook)

#### Token model: `api_tokens` table

```sql
CREATE TABLE api_tokens (
    id          BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
    user_id     BIGINT UNSIGNED NOT NULL,
    name        VARCHAR(255) NOT NULL,        -- e.g. "Kobo Libra"
    token       VARCHAR(64) NOT NULL UNIQUE,  -- hashed (SHA-256)
    plain_prefix VARCHAR(4) NOT NULL,         -- first 4 chars for identification
    last_used_at TIMESTAMP NULL,
    created_at  TIMESTAMP,
    updated_at  TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

- Token is 16 chars, lowercase alphanumeric (easy to type on e-reader keyboard)
- Stored **hashed** (SHA-256) in the database -- the plain token is shown only once at generation
- `plain_prefix` stores the first 4 chars so user can identify which token is which
- `name` is a user-given label (e.g. "Kobo Libra", "Kindle")

#### Token generation (web UI: Profile page)

1. User clicks "Generate API token"
2. User enters a name/label for the device
3. Server generates 16-char random alphanumeric token: `Str::random(16)`
4. Server stores SHA-256 hash + first 4 chars prefix
5. Plain token displayed **once** in a copyable dialog
6. User types it into KOReader plugin settings

#### Token invalidation (web UI: Profile page)

- List of active tokens: prefix (e.g. `ab3k...`), name, last used date
- "Revoke" button per token → deletes the row

#### Auth middleware: `varbook.auth`

```php
// Middleware logic:
// 1. Extract token from Authorization: Bearer <token>
// 2. Hash it with SHA-256
// 3. Look up in api_tokens table
// 4. If found: set Auth::user(), update last_used_at
// 5. If not found: return 401
```

## Book Identification

Each book is identified by its **koreader partial MD5 hash** (same algorithm KOReader uses internally via `Document:fastDigest()`). This hash is already computed by KOReader for each document and matches the `koreader_file_hash` column on the server.

Access in plugin: `self.document:fastDigest(self.document.file)` or equivalent method to get the document's partial hash.

## Core Feature: Position Tracking

### On Page Turn (`onPageUpdate`)

Each time the user turns a page, store a position record in local SQLite:

```sql
CREATE TABLE positions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    doc_hash    TEXT NOT NULL,     -- koreader partial MD5
    percentage  REAL NOT NULL,     -- 0-100 (e.g. 45.50)
    timestamp   INTEGER NOT NULL,  -- os.time() (unix epoch)
    synced      INTEGER DEFAULT 0, -- 0 = pending, 1 = synced
    xpointer    TEXT               -- xpointer position string (reflowable docs only)
);

CREATE INDEX idx_positions_unsynced ON positions (doc_hash, synced);
```

**Important considerations:**
- Page turns can be rapid (fast scrolling). Only record if percentage actually changed compared to last stored value.
- No debounce needed if we skip duplicates -- a page turn to a new position is a genuine event.

### Position Access

```lua
-- Percentage (0-100)
-- For paged documents:
local percentage = self.ui.paging:getLastPercent()

-- For rolling/reflowable documents:
local percentage = self.ui.rolling:getLastPercent()

-- Generic approach:
local percentage = self.view.state.page / self.ui.document:getPageCount() * 100
```

### Navigation

The plugin uses two navigation strategies depending on context:

**XPointer navigation** (preferred for KOReader-to-KOReader sync on reflowable documents):
```lua
-- When last_sync_client == "koreader" and xpointer is available
self.ui:handleEvent(Event:new("GotoXPointer", server.position))
```

**Page-based navigation** (fallback for cross-client sync or paged documents):
```lua
-- When last sync came from another client (e.g. web reader), or no xpointer available
local page_count = self.ui.document:getPageCount()
local target_page = math.floor(page_count * server_progress / 100)
self.ui:handleEvent(Event:new("GotoPage", target_page))
```

The decision logic checks: if the last sync came from KOReader, an xpointer is available from the server, and the document is reflowable → use xpointer (exact position). Otherwise → fall back to percentage-based page calculation. Precision is page-level in the fallback case, which is good enough for cross-device sync.

## Core Feature: Manual Sync

### Trigger

Menu entry: **Tools > Varbook > Sync now**

### Sync Flow

```
1. Ensure WiFi is on (prompt if not)
2. GET server position for this book
3. Compare server progress with current local percentage
4. IF server progress > local + 1%:
     → Navigate via xpointer (if koreader-to-koreader) or page (fallback)
     → Discard local unsynced positions (they predate the server state)
   ELSE:
     → Push all unsynced local positions (synced = 0) via batch endpoint
     → Mark pushed positions as synced (synced = 1)
5. Update local last_sync timestamp
6. Show result notification
```

### Step 1: Ensure Network

```lua
-- willRerunWhenOnline() enables WiFi if needed and re-calls the callback once connected
if NetworkMgr:willRerunWhenOnline(function() self:doSync() end) then
    return
end
self:doSync()
```

### Step 2: Fetch Server Position

```
GET /api/varbook/progress/{document_hash}
Headers: Authorization: Bearer <token>

Response 200:
{
    "progress": 45.50,
    "last_sync_at": "2026-05-04T21:30:00Z",
    "timestamp": 1717538400
}

Response 404: No progress data for this book (first sync)
```

### Step 3-4: Compare and Navigate

Comparison is **percentage-based** (not timestamp-based): navigate only if the server progress exceeds the local position by more than 1%. This avoids navigating backward when the server has a more recent timestamp but a lower percentage (e.g. after a re-read).

```lua
local server = api:getProgress(doc_hash)
local current = self:getPercentage() or 0

if server and server.progress > current + 1 then
    -- Server is ahead by >1%: another device has read further
    -- Use xpointer if last sync was from koreader and xpointer is available
    -- Otherwise fall back to page-based navigation from percentage
    ...
    navigated = true
end
-- If server is not ahead: stay at current position (local reading is ahead or equal)
```

If no server position exists (404), skip navigation.

When the server is ahead and navigation occurs, all local unsynced positions are discarded (they predate the server state). Otherwise, local positions are pushed to the server.

### Step 5: Push Unsynced Positions

```
POST /api/varbook/progress/{document_hash}/batch
Headers: Authorization: Bearer <token>
Content-Type: application/json

{
    "updates": [
        {
            "progress": 45.50,
            "timestamp": "2026-05-04T21:30:00Z",
            "position": "/body/DocFragment[5]/body/div/p[12]"
        },
        {
            "progress": 46.20,
            "timestamp": "2026-05-04T21:31:15Z",
            "position": "/body/DocFragment[5]/body/div/p[18]"
        }
    ]
}

Response 200:
{
    "message": "Progress updated",
    "data": {
        "progress": 46.20,
        "synced_count": 2
    }
}
```

### Step 6-7: Mark Synced

After successful push:
```sql
UPDATE positions SET synced = 1 WHERE doc_hash = ? AND synced = 0;
```

Store `last_sync_timestamp = os.time()` in LuaSettings (per document).

### Step 8: Result Notification

```lua
UIManager:show(Notification:new{
    text = string.format(_("Varbook: synced %d positions"), synced_count)
})
```

### Error Handling

- **No WiFi**: Prompt to enable WiFi via `NetworkMgr:beforeWifiAction()`
- **Auth failure (401)**: Show `InfoMessage` "Authentication failed. Check Varbook settings."
- **Server error (5xx)**: Show `InfoMessage` "Server error. Positions saved locally for next sync."
- **Book not found (404 on push)**: Show `InfoMessage` "Book not found on server. Upload it via the web interface first."
- **Partial failure**: Never mark positions as synced if the request failed.

## UI / Menu Structure

```
Tools >
  Varbook >
    Sync now           -- Trigger sync flow (main action)
    ─────────────
    Settings >
      Server URL       -- InputDialog
      API Token        -- InputDialog (16-char alphanumeric)
    ─────────────
    Status             -- InfoMessage showing:
                       --   Server: connected/disconnected
                       --   Pending positions: N
                       --   Last sync: datetime
```

## Server-Side Changes Required

### New API Endpoints

The plugin uses dedicated `/api/varbook/` endpoints authenticated via Bearer token.

All communication is **percentage-based only**. No XPointer, no CFI -- just progress (0-100) and timestamps.

#### `GET /api/varbook/progress/{documentHash}`

Returns the most recent progress for this book, regardless of which client set it.

```php
// Logic:
// 1. Find book by koreader_file_hash (same lookup as kosync)
// 2. Return book.progress + book.last_read_at
// 3. Return 404 if no book found
```

Response:
```json
{
    "progress": 45.50,
    "position": "/body/DocFragment[5]/body/div/p[12]",
    "last_sync_at": "2026-05-04T21:30:00Z",
    "last_sync_client": "koreader",
    "timestamp": 1717538400
}
```

- `position`: the xpointer from the last KOReader sync (null if last sync was from another client). Used for precise navigation on koreader-to-koreader sync.
- `last_sync_client`: which client last synced this book ("koreader", "web", etc.). Determines navigation strategy.

#### `POST /api/varbook/progress/{documentHash}/batch`

Accepts batch position updates (percentage only).

```php
// Validation:
// - updates: required|array|min:1|max:500
// - updates.*.progress: required|numeric|min:0|max:100
// - updates.*.timestamp: required|date
// - updates.*.position: nullable|string|max:500

// Logic:
// 1. Find book by koreader_file_hash
// 2. Sort updates by timestamp
// 3. For each update, call processSyncEvent() with:
//    - client: 'koreader'
//    - externalIdentifier: documentHash
//    - progress: update.progress
//    - rawPosition: update.position (xpointer string, if available)
// 4. Return final progress + synced count
```

### Authentication Middleware

Both endpoints use the new `varbook.auth` middleware (Bearer token).

### Route Registration

```php
Route::prefix('api/varbook')
    ->withoutMiddleware([StartSession, ShareErrors, VerifyCsrfToken])
    ->middleware(['varbook.auth'])
    ->group(function () {
        Route::get('progress/{documentHash}', [VarbookController::class, 'getProgress']);
        Route::post('progress/{documentHash}/batch', [VarbookController::class, 'batchProgress']);
    });
```

### Controller: VarbookController

Lean controller, delegates to existing `ReadingSessionService`:

```php
class VarbookController extends Controller
{
    // GET /api/varbook/progress/{documentHash}
    public function getProgress(string $documentHash): JsonResponse
    {
        $book = $this->findBookOrFail($documentHash);

        return response()->json([
            'progress' => (float) $book->progress,
            'last_sync_at' => $book->last_read_at?->toIso8601String(),
            'timestamp' => $book->last_read_at?->timestamp ?? 0,
        ]);
    }

    // POST /api/varbook/progress/{documentHash}/batch
    public function batchProgress(Request $request, string $documentHash): JsonResponse
    {
        $book = $this->findBookOrFail($documentHash);

        // Validate, sort by timestamp, process each via ReadingSessionService
        // Return final progress + synced_count
    }
}
```

### Web UI: Token Management (Profile page)

Add an "API Tokens" section to the existing Profile page.

#### Display
- List of active tokens in a table:
  | Token | Name | Last used | Actions |
  |-------|------|-----------|---------|
  | `ab3k...` | Kobo Libra | 2 hours ago | [Revoke] |
  | `xm9f...` | Kindle | Never | [Revoke] |

#### Generate token
- Button "Generate new token"
- Modal/dialog: input for device name (required)
- On confirm: POST to API, display plain token **once** in a copyable field
- Warning: "Copy this token now. It won't be shown again."

#### Revoke token
- Click "Revoke" → confirmation dialog → DELETE to API
- Token is immediately invalidated

#### API endpoints for token management (Sanctum-authenticated, web session)

```
GET    /api/tokens              → list user's tokens (prefix, name, last_used_at)
POST   /api/tokens              → generate new token { name: "Kobo Libra" }
                                  → returns { token: "ab3kxm9f12qw5678", name: "..." }
DELETE /api/tokens/{id}         → revoke token
```

## Data Cleanup

Synced positions older than 30 days can be pruned from the local SQLite database to save space. This cleanup runs at plugin initialization:

```sql
DELETE FROM positions WHERE synced = 1 AND timestamp < strftime('%s', 'now') - (30 * 86400);
```

## Typical Usage Scenario

```
EVENING (Kobo + KOReader):
  1. Open book, read for 1 hour
  2. Each page turn → percentage stored in local SQLite
  3. Before bed, tap "Tools > Varbook > Sync now"
  4. Plugin enables WiFi, pushes 50 position records
  5. Server now knows: book is at 45.5%, last update 22:30

MORNING (Web PWA):
  1. Open book in web reader
  2. Web reader fetches progress → 45.5%
  3. Web uses cfiFromPercentage(0.455) → navigates ~same spot
  4. Read during commute, advance to 52%
  5. Web pushes progress automatically

EVENING (Kobo + KOReader):
  1. Open book, tap "Varbook > Sync now"
  2. Server says: 52%, timestamp=today 08:30 (newer than last sync)
  3. Plugin does GotoPercentage(0.52) → navigates to ~52%
  4. Continue reading...
```

## Future Enhancements (v2+)

- Auto-sync on suspend (`onSuspend` + `NetworkMgr:turnOnWifi`)
- Auto-sync on document close (`onCloseDocument`)
- Remote library browsing (replace OPDS)
- Sync status indicator in reader footer
- Configurable sync strategy (prompt before navigating vs. silent)

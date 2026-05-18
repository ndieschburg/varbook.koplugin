# Varbook KOReader Plugin

KOReader plugin to synchronize reading progress with a [Varbook (BookShelf)](https://github.com/your-repo/bookshelf) server.

Read on your Kobo in the evening with KOReader, then pick up where you left off the next morning on the Varbook web reader (and vice versa).

## How It Works

### Local Tracking

On every page turn, the plugin records the **reading percentage** and a **timestamp** into a local SQLite database on the e-reader. These positions accumulate in the background with no network access required.

### Manual Sync

When you tap **Sync now** in the menu, the plugin:

1. Enables WiFi if needed
2. Fetches the server's progress (percentage + timestamp)
3. If the server is more recent, navigates to that position automatically
4. Pushes all unsynced local positions to the server in a single batch
5. Marks those positions as synced

### Precision

Synchronization is **percentage-based** (not exact character position). Accuracy is page-level -- you'll land within 1-2 pages of where you were, which is more than enough for regular reading.

## Prerequisites

- **KOReader** installed on a Kobo (or other supported device)
- **Varbook (BookShelf)** v1.x+ with the `/api/varbook/` endpoints deployed
- An **API token** generated from the Varbook web interface
- Books must be the **exact same EPUB files** on the e-reader and the server (same file = same hash). The easiest way is to download books onto the Kobo via Varbook's OPDS catalog.

## Installation (Kobo)

### 1. Connect the Kobo via USB

Plug the Kobo into your computer. It will appear as an external drive.

### 2. Copy the plugin

Copy the `varbook.koplugin` folder into KOReader's plugins directory:

```
<KOBO>/.adds/koreader/plugins/varbook.koplugin/
```

The folder should contain:

```
varbook.koplugin/
  _meta.lua
  main.lua
  varbook_api.lua
  varbook_db.lua
```

### 3. Eject and restart

Safely eject the Kobo, then restart KOReader (or the Kobo itself).

## Configuration

### 1. Generate an API token in Varbook

1. Log into the Varbook web interface
2. Go to **Profile**
3. In the **API Tokens** section, click **Generate new token**
4. Enter a name for the device (e.g. "Kobo Libra")
5. **Copy the displayed token** -- it will not be shown again

### 2. Configure the plugin on KOReader

1. Open any book in KOReader
2. Open the menu (tap the top of the screen)
3. **Tools > Varbook > Server URL**: enter the server URL (e.g. `https://your-domain.com`)
4. **Tools > Varbook > API Token**: enter the 16-character token

## Usage

### Syncing

1. Open the book you want to sync in KOReader
2. Menu > **Tools > Varbook > Sync now**
3. The plugin enables WiFi if needed, syncs, and displays the result

### Quick Sync via Gesture (recommended)

Instead of navigating through the menu each time, you can assign **Varbook Sync** to any gesture (tap zone, swipe, long-press...) for one-tap access:

1. Open the top menu in KOReader
2. Go to **Settings (gear icon) > Taps and gestures > Gesture manager**
3. Pick a gesture you want to use, for example:
   - **Top right corner tap** (convenient one-hand access)
   - **Two-finger tap**
   - **Long-press bottom right corner**
4. In the action list, scroll to find **Varbook Sync**
5. Select it and confirm

From now on, that gesture triggers a sync directly -- WiFi is enabled automatically if needed.

> **Tip**: A good default is **top right corner tap** -- easy to reach on a Kobo, and rarely conflicts with other gestures.

### Checking status

Menu > **Tools > Varbook > Status** shows:
- Configured URL and token
- Number of positions pending sync
- Date of last sync

### Typical scenario

```
EVENING (Kobo + KOReader):
  1. Read for an hour
  2. Each page turn is recorded locally
  3. Before bed: Tools > Varbook > Sync now
  4. Plugin pushes the 50 accumulated positions

MORNING (Web / phone):
  1. Open the book in the Varbook web reader
  2. The reader fetches progress and navigates to the right spot
  3. Read during commute, advance to 52%

EVENING (Kobo + KOReader):
  1. Open the book, Tools > Varbook > Sync now
  2. Server says 52%, more recent than last sync
  3. KOReader navigates to 52%, continue reading
```

## Book Identification

The plugin identifies books by a **partial MD5 hash** (KOReader's native algorithm). For sync to work, the EPUB file must be **bit-for-bit identical** on the e-reader and the server.

The simplest way to ensure this:

1. Upload the book to Varbook via the web interface
2. Download the book onto the Kobo via Varbook's **OPDS catalog** (`https://your-server/opds`)

If the hash doesn't match (book uploaded from two different sources), the server will return a 404 error during sync.

## Local Storage

Positions are stored in `varbook_positions.sqlite3` in KOReader's settings directory. Synced positions older than 30 days are automatically cleaned up.

Settings (URL, token, sync timestamps) are stored in `varbook.lua` in the same directory.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Authentication failed" | Check the token in Varbook > API Token. Generate a new token if needed. |
| "Book not found on server" | The book isn't in Varbook or the hash doesn't match. Re-download via OPDS. |
| "Network error" | Check WiFi connection. Positions are kept locally and will sync next time. |
| Varbook menu doesn't appear | Ensure `varbook.koplugin` is in `.adds/koreader/plugins/`. Restart KOReader. |
| Position is off by a few pages | Expected -- sync is percentage-based, accuracy is page-level. |

## Uninstall

Delete the `varbook.koplugin` folder from `.adds/koreader/plugins/` and optionally remove `varbook_positions.sqlite3` and `varbook.lua` from KOReader's settings directory.

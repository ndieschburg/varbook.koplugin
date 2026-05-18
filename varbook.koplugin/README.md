# Varbook Sync - KOReader Plugin

Synchronize reading progress between KOReader and a [Bookshelf (Varbook)](https://github.com/ndieschburg/bookshelf) server.

Read on your Kobo in the evening, then pick up where you left off the next morning on the web reader -- and vice versa.

## Features

- **Automatic local tracking**: every page turn is recorded in a local SQLite database, no network needed
- **One-tap sync**: push all accumulated positions and pull the latest server progress in a single action
- **Gesture support**: assign sync to any tap zone, swipe, or long-press for quick access
- **Offline-first**: positions are stored locally and synced whenever you're ready
- **Cross-device**: works alongside the Bookshelf web reader, Moon+ Reader (WebDAV), and other Varbook-compatible clients

## Prerequisites

- **KOReader** on a Kobo (or other supported device)
- **Bookshelf (Varbook)** server with the `/api/varbook/` endpoints enabled
- An **API token** generated from the Bookshelf web interface
- Books must be the **same EPUB files** on both devices (same file = same hash). The easiest way is to download books via the Bookshelf OPDS catalog.

## Installation

### Via the KOReader App Store (recommended)

The easiest way to install is through the [KOReader App Store](https://github.com/omer-faruq/appstore.koplugin):

1. Install the App Store plugin if you don't have it yet (see [its README](https://github.com/omer-faruq/appstore.koplugin#installation) for instructions)
2. Open KOReader
3. Go to **Search > Plugin store**
4. Search for **Varbook Sync**
5. Tap **Install**
6. Restart KOReader

Updates will be available directly from the App Store.

### Manual installation

Connect your e-reader via USB and copy the `varbook.koplugin` folder into KOReader's plugins directory:

```
<KOBO>/.adds/koreader/plugins/varbook.koplugin/
```

Restart KOReader after copying.

## Configuration

### 1. Generate an API token

1. Log into the Bookshelf web interface
2. Go to **Profile**
3. In **API Tokens**, click **Generate new token**
4. Name it (e.g. "Kobo Libra") and **copy the token** -- it won't be shown again

### 2. Configure the plugin

1. Open any book in KOReader
2. Open the menu (tap the top of the screen)
3. **Tools > Varbook > Server URL**: enter your server URL (e.g. `https://bookshelf.example.com`)
4. **Tools > Varbook > API Token**: enter the token

## Usage

### Sync

Menu > **Tools > Varbook > Sync now**

The plugin enables WiFi if needed, fetches the server's latest position, navigates there if it's more recent, and pushes all local positions in a batch.

### Quick sync via gesture (recommended)

Assign **Varbook Sync** to any gesture for one-tap access:

1. **Settings > Taps and gestures > Gesture manager**
2. Pick a gesture (e.g. top right corner tap)
3. Select **Varbook Sync**

### Status

Menu > **Tools > Varbook > Status** shows the configured URL, pending positions count, and last sync date.

## How sync works

```
EVENING (Kobo):
  Read for an hour → page turns recorded locally
  Sync now → 50 positions pushed to server

MORNING (Web/phone):
  Open book in web reader → picks up at last synced position
  Read to 52%

EVENING (Kobo):
  Sync now → server says 52%, KOReader navigates there
  Continue reading
```

Synchronization is **percentage-based** (page-level accuracy, within 1-2 pages).

## Book identification

Books are identified by a **partial MD5 hash** (KOReader's native algorithm). For sync to work, the EPUB must be identical on both devices.

The simplest approach:
1. Upload the book to Bookshelf via the web interface
2. Download it onto the Kobo via the **OPDS catalog** (`https://your-server/opds`)

## Local storage

- Positions: `varbook_positions.sqlite3` in KOReader's settings directory (auto-cleanup after 30 days)
- Settings: `varbook.lua` in the same directory

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Authentication failed" | Check the token. Generate a new one if needed. |
| "Book not found on server" | The book isn't on the server or the hash doesn't match. Re-download via OPDS. |
| "Network error" | Check WiFi. Positions are kept locally and will sync next time. |
| Plugin menu doesn't appear | Ensure `varbook.koplugin` is in the plugins directory. Restart KOReader. |
| Position off by a few pages | Expected -- sync is percentage-based. |

## Uninstall

Delete `varbook.koplugin` from the plugins directory. Optionally remove `varbook_positions.sqlite3` and `varbook.lua` from the settings directory.

## License

MIT

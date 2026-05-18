--[[
    Varbook KOReader Plugin
    Synchronizes reading progress with a Varbook (BookShelf) server.

    - Tracks page turns locally in SQLite (percentage + timestamp)
    - Manual sync via menu button: pull server position, push local positions
    - Uses pivot format (spine_index + spine_percent) for cross-device compatibility
]]--

local DataStorage = require("datastorage")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Dispatcher = require("dispatcher")
local _ = require("gettext")

logger.dbg("Varbook: loading plugin modules")
local ok1, VarbookAPI = pcall(require, "varbook_api")
if not ok1 then
    logger.warn("Varbook: FAILED to load varbook_api:", VarbookAPI)
    VarbookAPI = nil
end
local ok2, VarbookDB = pcall(require, "varbook_db")
if not ok2 then
    logger.warn("Varbook: FAILED to load varbook_db:", VarbookDB)
    VarbookDB = nil
end
logger.dbg("Varbook: modules loaded, api=", ok1, "db=", ok2)

local Varbook = WidgetContainer:extend{
    name = "varbook",
    is_doc_only = true,
}

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/varbook.lua"

function Varbook:init()
    logger.dbg("Varbook: plugin init called")
    self.settings = LuaSettings:open(SETTINGS_PATH)
    self.doc_hash = nil
    self.last_percentage = nil
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    logger.dbg("Varbook: menu registered OK")
end

--- Register Dispatcher action so users can assign "Varbook Sync" to any gesture.
function Varbook:onDispatcherRegisterActions()
    Dispatcher:registerAction("varbook_sync_now", {
        category = "none",
        event = "VarbookSyncNow",
        title = _("Varbook Sync"),
        general = true,
        reader = true,
    })
end

--- Handle the Dispatcher event triggered by gesture/shortcut.
function Varbook:onVarbookSyncNow()
    self:syncNow()
end

--- Get document partial MD5 hash (same hash stored on Varbook server).
function Varbook:getDocHash()
    if self.doc_hash then
        return self.doc_hash
    end
    self.doc_hash = self.ui.doc_settings:readSetting("partial_md5_checksum")
    return self.doc_hash
end

--- Get the basename of the current document file.
-- @return string|nil Filename without path (e.g. "book.epub")
function Varbook:getFilename()
    local filepath = self.ui.document.file
    if not filepath then return nil end
    return filepath:match("([^/]+)$")
end

--- Get current reading percentage (0-100).
function Varbook:getPercentage()
    local pct
    if self.ui.document.info.has_pages then
        pct = self.ui.paging:getLastPercent()
    else
        pct = self.ui.rolling:getLastPercent()
    end
    -- getLastPercent() returns 0-1, convert to 0-100
    -- Round to 2 decimal places (0.01% precision) for large books (10,000+ pages)
    return pct and math.floor(pct * 10000) / 100 or nil
end

--- Get current xpointer position (rolling/reflowable documents only).
-- @return string|nil XPointer string, or nil for paged documents
function Varbook:getXPointer()
    if self.ui.document.info.has_pages then
        return nil
    end
    return self.ui.rolling:getLastProgress()
end

--- Get the last sync timestamp for the current document.
function Varbook:getLastSyncTimestamp()
    local doc_hash = self:getDocHash()
    if not doc_hash then return 0 end
    local per_doc = self.settings:readSetting("last_sync", {})
    return per_doc[doc_hash] or 0
end

--- Save the last sync timestamp for the current document.
function Varbook:setLastSyncTimestamp(ts)
    local doc_hash = self:getDocHash()
    if not doc_hash then return end
    local per_doc = self.settings:readSetting("last_sync", {})
    per_doc[doc_hash] = ts
    self.settings:saveSetting("last_sync", per_doc)
    self.settings:flush()
end

function Varbook:isConfigured()
    local url = self.settings:readSetting("server_url")
    local token = self.settings:readSetting("token")
    return url and url ~= "" and token and token ~= ""
end

function Varbook:getAPI()
    return VarbookAPI:new(
        self.settings:readSetting("server_url"),
        self.settings:readSetting("token")
    )
end

-- ==========================================
-- Pivot: spine mapping & navigation
-- ==========================================

--- Extract the 1-based DocFragment number from an XPointer.
-- @param xpointer string XPointer string
-- @return number 1-based DocFragment number, or 1 for mono-file EPUB
local function fragNFromXPointer(xpointer)
    local n = xpointer:match("DocFragment%[(%d+)%]")
    return n and tonumber(n) or 1
end

--- Read the OPF content from the EPUB archive.
-- Tries CREngine's getDocumentFileContent first, then falls back to unzip CLI.
-- @return string|nil OPF XML content
function Varbook:readOpfContent()
    -- Method 1: CREngine API
    if self.ui.document.getDocumentFileContent then
        local ok_c, container = pcall(
            self.ui.document.getDocumentFileContent,
            self.ui.document, "META-INF/container.xml")
        if ok_c and container and container ~= "" then
            local opf_path = container:match('full%-path="([^"]+)"')
            if opf_path then
                local ok_o, opf = pcall(
                    self.ui.document.getDocumentFileContent,
                    self.ui.document, opf_path)
                if ok_o and opf and opf ~= "" then
                    logger.dbg("Varbook: OPF read via CREngine (",
                        #opf, "bytes, path=", opf_path, ")")
                    return opf
                end
            end
        end
        logger.dbg("Varbook: getDocumentFileContent failed, trying unzip")
    end

    -- Method 2: shell unzip fallback (BusyBox on Kobo/PocketBook)
    local epub_path = self.ui.document.file
    if not epub_path then return nil end

    local escaped = "'" .. epub_path:gsub("'", "'\\''") .. "'"
    local h1 = io.popen("unzip -p " .. escaped .. " META-INF/container.xml 2>/dev/null")
    if not h1 then return nil end
    local container = h1:read("*a")
    h1:close()
    if not container or container == "" then return nil end

    local opf_path = container:match('full%-path="([^"]+)"')
    if not opf_path then return nil end

    local escaped_opf = "'" .. opf_path:gsub("'", "'\\''") .. "'"
    local h2 = io.popen("unzip -p " .. escaped .. " " .. escaped_opf .. " 2>/dev/null")
    if not h2 then return nil end
    local opf = h2:read("*a")
    h2:close()

    if opf and opf ~= "" then
        logger.dbg("Varbook: OPF read via unzip (", #opf, "bytes)")
        return opf
    end
    return nil
end

--- Parse the OPF XML to extract spine hrefs in order.
-- @param opf string OPF XML content
-- @return table Array of href strings in OPF spine order
local function parseSpineFromOpf(opf)
    local manifest = {}
    for tag in opf:gmatch("<item[^>]+>") do
        local id = tag:match('id="([^"]*)"')
        local href = tag:match('href="([^"]*)"')
        if id and href then
            manifest[id] = href
        end
    end

    local hrefs = {}
    for tag in opf:gmatch("<itemref[^>]+>") do
        local idref = tag:match('idref="([^"]*)"')
        if idref and manifest[idref] then
            table.insert(hrefs, manifest[idref])
        end
    end
    return hrefs
end

--- Build the mapping between OPF spine indices and CREngine DocFragment numbers.
-- Result is cached per document.
-- @return table {frag_for_spine, spine_for_frag, spine_hrefs, offset, total_frags, spine_count}
function Varbook:getSpineMapping()
    local doc_hash = self:getDocHash()
    if self._spine_map_hash == doc_hash and self._spine_map then
        return self._spine_map
    end

    local result = {
        frag_for_spine = {}, -- spine index (0-based) → DocFragment N (1-based)
        spine_for_frag = {}, -- DocFragment N (1-based) → spine index (0-based)
        spine_hrefs = {},    -- spine index (0-based) → href string
        offset = 0,
        total_frags = 0,
        spine_count = 0,
    }

    -- Count DocFragments
    for i = 1, 5000 do
        if self.ui.document:isXPointerInDocument(
                "/body/DocFragment[" .. i .. "]/body") then
            result.total_frags = i
        else
            break
        end
    end

    -- Read and parse OPF spine
    local opf = self:readOpfContent()
    local spine_hrefs = opf and parseSpineFromOpf(opf) or {}
    result.spine_count = #spine_hrefs
    for i, href in ipairs(spine_hrefs) do
        result.spine_hrefs[i - 1] = href
    end

    logger.dbg("Varbook: spine mapping: total_frags=", result.total_frags,
        "spine_count=", result.spine_count)

    if result.spine_count == 0 then
        -- No OPF data: assume 1:1
        logger.dbg("Varbook: no OPF data, assuming 1:1 mapping")
        for i = 1, result.total_frags do
            result.frag_for_spine[i - 1] = i
            result.spine_for_frag[i] = i - 1
        end
    elseif result.total_frags == result.spine_count then
        -- 1:1 mapping
        for i = 0, result.spine_count - 1 do
            result.frag_for_spine[i] = i + 1
            result.spine_for_frag[i + 1] = i
        end
    else
        -- Offset: extra DocFragments assumed at beginning
        result.offset = result.total_frags - result.spine_count
        logger.dbg("Varbook: frag/spine mismatch! offset=", result.offset)
        if result.offset > 0 then
            for i = 0, result.spine_count - 1 do
                result.frag_for_spine[i] = i + 1 + result.offset
                result.spine_for_frag[i + 1 + result.offset] = i
            end
        else
            local frag_idx = 1
            for i = 0, result.spine_count - 1 do
                if frag_idx <= result.total_frags then
                    result.frag_for_spine[i] = frag_idx
                    result.spine_for_frag[frag_idx] = i
                    frag_idx = frag_idx + 1
                end
            end
        end
    end

    self._spine_map = result
    self._spine_map_hash = doc_hash
    return result
end

--- Find the first and last page of a DocFragment using binary search on getPageXPointer.
-- ~22 calls for a 1862-page book (~20ms).
-- @param frag_n number 1-based DocFragment number
-- @return number, number first_page, last_page (1-based) or nil, nil
function Varbook:findFragPageRange(frag_n)
    local page_count = self.ui.document:getPageCount()

    -- Binary search: first page where DocFragment >= frag_n
    local lo, hi = 1, page_count
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local xp = self.ui.document:getPageXPointer(mid)
        local n = tonumber(xp:match("DocFragment%[(%d+)%]") or "0")
        if n < frag_n then
            lo = mid + 1
        else
            hi = mid
        end
    end

    -- Verify we landed on the right fragment
    local check_xp = self.ui.document:getPageXPointer(lo)
    local check_n = tonumber(check_xp:match("DocFragment%[(%d+)%]") or "0")
    if check_n ~= frag_n then
        logger.dbg("Varbook: findFragPageRange: DocFragment[" .. frag_n .. "] not found",
            "(landed on DocFragment[" .. check_n .. "] at page " .. lo .. ")")
        return nil, nil
    end
    local first_page = lo

    -- Binary search: last page where DocFragment <= frag_n
    lo, hi = first_page, page_count
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local xp = self.ui.document:getPageXPointer(mid)
        local n = tonumber(xp:match("DocFragment%[(%d+)%]") or "0")
        if n <= frag_n then
            lo = mid
        else
            hi = mid - 1
        end
    end

    return first_page, lo
end

--- Compute spine_percent: page-based ratio of current position within a DocFragment.
-- Uses getCurrentPage() directly instead of pixel-based position comparison,
-- which avoids non-linear pixel/page mapping issues in CREngine.
-- @param frag_n number 1-based DocFragment number
-- @return number Ratio 0-1
function Varbook:computeSpinePercent(frag_n)
    local first_page, last_page = self:findFragPageRange(frag_n)
    if not first_page then return 0 end

    local pages_in_frag = last_page - first_page
    if pages_in_frag <= 0 then return 0 end

    local current_page = self.ui.document:getCurrentPage()
    current_page = math.max(first_page, math.min(last_page, current_page))

    return math.max(0, math.min(1, (current_page - first_page) / pages_in_frag))
end

--- Extract a pivot from the current reading position.
-- @return table|nil Pivot data {spine_index, spine_href, spine_percent, source}
function Varbook:extractPivot()
    if self.ui.document.info.has_pages then return nil end

    local xpointer = self:getXPointer()
    if not xpointer then return nil end

    local frag_n = fragNFromXPointer(xpointer)
    local mapping = self:getSpineMapping()
    local spine_index = mapping.spine_for_frag[frag_n]
    if spine_index == nil then
        spine_index = frag_n - 1
    end

    local spine_percent = self:computeSpinePercent(frag_n)
    local spine_href = mapping.spine_hrefs[spine_index] or ""

    logger.dbg("Varbook: extractPivot",
        "DocFragment[" .. frag_n .. "] → spine_index=" .. spine_index,
        "spine_percent=" .. string.format("%.4f", spine_percent),
        "spine_href=" .. spine_href)

    return {
        spine_index = spine_index,
        spine_href = spine_href,
        spine_percent = math.floor(spine_percent * 10000) / 10000,
        source = "koreader",
    }
end

--- Navigate to a pivot position.
-- 1. GotoXPointer to land on the correct DocFragment
-- 2. Binary search for the page range of that fragment
-- 3. Advance by spine_percent pages within it
-- @param pivot table {spine_index, spine_href, spine_percent}
-- @return boolean True if navigation succeeded
function Varbook:resolvePivot(pivot)
    if self.ui.document.info.has_pages then return false end

    local mapping = self:getSpineMapping()

    -- Resolve spine_index → DocFragment
    local frag_n = mapping.frag_for_spine[pivot.spine_index]

    -- Validate with spine_href
    if frag_n and pivot.spine_href and pivot.spine_href ~= "" then
        local expected_href = mapping.spine_hrefs[pivot.spine_index]
        if expected_href and expected_href ~= pivot.spine_href then
            logger.dbg("Varbook: resolvePivot href mismatch!",
                "expected=" .. expected_href, "got=" .. pivot.spine_href)
            frag_n = nil
        end
    end

    -- Fallback: search by href
    if not frag_n and pivot.spine_href and pivot.spine_href ~= "" then
        for si, href in pairs(mapping.spine_hrefs) do
            if href == pivot.spine_href then
                frag_n = mapping.frag_for_spine[si]
                logger.dbg("Varbook: resolvePivot found href at spine_index=", si)
                break
            end
        end
    end

    -- Last resort: 1:1
    if not frag_n then
        frag_n = pivot.spine_index + 1
    end

    -- Step 1: Navigate to DocFragment start
    local start_xp = "/body/DocFragment[" .. frag_n .. "]/body"
    if not self.ui.document:isXPointerInDocument(start_xp) then
        logger.dbg("Varbook: resolvePivot FAILED DocFragment[" .. frag_n .. "] not in document")
        return false
    end
    self.ui:handleEvent(Event:new("GotoXPointer", start_xp))

    -- Step 2: Advance by spine_percent within the chapter
    if pivot.spine_percent > 0 then
        local first_page, last_page = self:findFragPageRange(frag_n)
        if first_page then
            local pages_in_frag = last_page - first_page
            local target_page = first_page + math.floor(pages_in_frag * pivot.spine_percent)
            target_page = math.max(first_page, math.min(last_page, target_page))

            logger.dbg("Varbook: resolvePivot",
                "spine_index=" .. pivot.spine_index,
                "→ DocFragment[" .. frag_n .. "]",
                "pages=" .. first_page .. "-" .. last_page .. " (" .. (pages_in_frag + 1) .. "p)",
                "spine_percent=" .. pivot.spine_percent,
                "→ target_page=" .. target_page)

            self.ui:handleEvent(Event:new("GotoPage", target_page))
        else
            logger.dbg("Varbook: resolvePivot",
                "spine_index=" .. pivot.spine_index,
                "→ DocFragment[" .. frag_n .. "] (start, page range not found)")
        end
    else
        logger.dbg("Varbook: resolvePivot",
            "spine_index=" .. pivot.spine_index,
            "→ DocFragment[" .. frag_n .. "] (start)")
    end

    return true
end

-- ==========================================
-- Page turn tracking
-- ==========================================

function Varbook:onPageUpdate()
    if not self:isConfigured() then return end

    local doc_hash = self:getDocHash()
    if not doc_hash then return end

    local percentage = self:getPercentage()
    if percentage == nil then return end

    if self.last_percentage and self.last_percentage == percentage then
        return
    end
    self.last_percentage = percentage

    local xpointer = self:getXPointer()
    logger.dbg("Varbook: page update", percentage, "%",
        xpointer and ("xpointer=" .. xpointer) or "no xpointer (paged document)")
    VarbookDB:addPosition(doc_hash, percentage, xpointer)
end

function Varbook:onCloseDocument()
    VarbookDB:close()
end

-- ==========================================
-- Sync logic
-- ==========================================

function Varbook:doSync()
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure Varbook server URL and token first."),
        })
        return
    end

    local doc_hash = self:getDocHash()
    if not doc_hash then
        UIManager:show(InfoMessage:new{
            text = _("Cannot identify this document."),
        })
        return
    end

    local api = self:getAPI()
    local filename = self:getFilename()
    local navigated = false
    local synced_count = 0

    -- Step 1: Pull server progress
    local server, err = api:getProgress(doc_hash, filename)

    if err == "unauthorized" then
        UIManager:show(InfoMessage:new{
            text = _("Authentication failed. Check Varbook settings."),
        })
        return
    elseif err == "network_error" then
        UIManager:show(InfoMessage:new{
            text = _("Network error. Positions saved locally."),
        })
        return
    end

    -- Step 2: Check if server has a newer sync than our last koreader sync
    local last_local_sync = self:getLastSyncTimestamp()
    local server_timestamp = server and server.timestamp or 0
    local server_client = server and server.last_sync_client
    local server_progress = server and server.progress or 0
    local current = self:getPercentage() or 0

    logger.dbg("Varbook: === SYNC DECISION ===")
    logger.dbg("Varbook:   server_client=", server_client)
    logger.dbg("Varbook:   server_timestamp=", server_timestamp,
        "(", server_timestamp > 0 and os.date("%Y-%m-%d %H:%M:%S", server_timestamp) or "N/A", ")")
    logger.dbg("Varbook:   last_local_sync=", last_local_sync,
        "(", last_local_sync > 0 and os.date("%Y-%m-%d %H:%M:%S", last_local_sync) or "never", ")")
    logger.dbg("Varbook:   server_progress=", server_progress, "% local=", current, "%")
    logger.dbg("Varbook:   has_pivot=", server and server.pivot ~= nil,
        "has_xpointer=", server and server.position ~= nil and server.position ~= "")
    logger.dbg("Varbook:   server_is_newer=", server_timestamp > last_local_sync)

    if server and server_timestamp > last_local_sync then
        -- Server has a sync strictly more recent than our last koreader sync
        if server_client == "koreader" then
            -- Last sync came from koreader (another device): use xpointer
            if server.position and server.position ~= ""
                and not self.ui.document.info.has_pages then
                logger.dbg("Varbook: nav XPOINTER (from another koreader device)")
                logger.dbg("Varbook:   xpointer=", server.position)
                self.ui:handleEvent(Event:new("GotoXPointer", server.position))
                navigated = true
            else
                logger.dbg("Varbook: koreader sync but no usable xpointer, fallback PERCENTAGE")
                local page_count = self.ui.document:getPageCount()
                local target_page = math.floor(page_count * server_progress / 100)
                logger.dbg("Varbook:   target_page=", target_page, "/", page_count)
                self.ui:handleEvent(Event:new("GotoPage", target_page))
                navigated = true
            end
        else
            -- Last sync came from another client (web, moon, etc.): use pivot (spine)
            if server.pivot and not self.ui.document.info.has_pages then
                logger.dbg("Varbook: nav PIVOT (from client:", server_client, ")")
                logger.dbg("Varbook:   spine_index=", server.pivot.spine_index,
                    "spine_href=", server.pivot.spine_href,
                    "spine_percent=", server.pivot.spine_percent,
                    "source=", server.pivot.source)
                local ok = self:resolvePivot(server.pivot)
                if not ok then
                    logger.dbg("Varbook: pivot resolve FAILED → fallback PERCENTAGE")
                    local page_count = self.ui.document:getPageCount()
                    local target_page = math.floor(page_count * server_progress / 100)
                    logger.dbg("Varbook:   target_page=", target_page, "/", page_count)
                    self.ui:handleEvent(Event:new("GotoPage", target_page))
                end
            else
                logger.dbg("Varbook: no pivot available, fallback PERCENTAGE")
                local page_count = self.ui.document:getPageCount()
                local target_page = math.floor(page_count * server_progress / 100)
                logger.dbg("Varbook:   target_page=", target_page, "/", page_count)
                self.ui:handleEvent(Event:new("GotoPage", target_page))
            end
            navigated = true
        end
    else
        logger.dbg("Varbook: no navigation needed",
            "(server_timestamp <= last_local_sync or no server data)")
    end

    -- Step 3: Handle local unsynced positions
    local positions = VarbookDB:getUnsyncedPositions(doc_hash)

    if navigated then
        logger.dbg("Varbook: discarding", #positions, "local positions (server was ahead)")
        VarbookDB:markSynced(doc_hash)
    elseif #positions > 0 then
        logger.dbg("Varbook: pushing", #positions, "positions")
        local pivot = self:extractPivot()

        local count, push_err = api:pushBatch(doc_hash, positions, pivot, filename)

        if push_err == "unauthorized" then
            UIManager:show(InfoMessage:new{
                text = _("Authentication failed. Check Varbook settings."),
            })
            return
        elseif push_err == "book_not_found" then
            UIManager:show(InfoMessage:new{
                text = _("Book not found on server. Upload it via the web interface first."),
            })
            return
        elseif push_err then
            UIManager:show(InfoMessage:new{
                text = _("Server error. Positions saved locally for next sync."),
            })
            return
        end

        VarbookDB:markSynced(doc_hash)
        synced_count = count or #positions
    end

    self:setLastSyncTimestamp(os.time())

    local msg
    if navigated and server.pivot and server_client ~= "koreader" then
        msg = string.format(_("Navigated to spine %d position %.0f%%."),
            server.pivot.spine_index, server.pivot.spine_percent * 100)
    elseif navigated then
        msg = string.format(_("Synced to %.2f%%."), server.progress)
    elseif synced_count > 0 then
        msg = string.format(_("Pushed %d positions."), synced_count)
    else
        msg = _("Already in sync.")
    end
    UIManager:show(Notification:new{ text = msg })
end

function Varbook:syncNow()
    if NetworkMgr:willRerunWhenOnline(function() self:doSync() end) then
        return
    end
    self:doSync()
end

-- ==========================================
-- Menu
-- ==========================================

function Varbook:addToMainMenu(menu_items)
    menu_items.varbook = {
        text = _("Varbook"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                enabled_func = function()
                    return self:isConfigured()
                end,
                callback = function()
                    self:syncNow()
                end,
                separator = true,
            },
            {
                text = _("Server URL"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showServerURLDialog(touchmenu_instance)
                end,
            },
            {
                text = _("API Token"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showTokenDialog(touchmenu_instance)
                end,
            },
            {
                text = _("Pair with code"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showPairingDialog(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = _("Status"),
                callback = function()
                    self:showStatus()
                end,
            },
        },
    }
end

function Varbook:showServerURLDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Varbook server URL"),
        input = self.settings:readSetting("server_url") or "https://",
        input_hint = "https://bookshelf.example.com",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local url = dialog:getInputText()
                    url = url:gsub("/+$", "")
                    self.settings:saveSetting("server_url", url)
                    self.settings:flush()
                    UIManager:close(dialog)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Varbook:showTokenDialog(touchmenu_instance)
    local current = self.settings:readSetting("token") or ""
    local masked = current ~= "" and (current:sub(1, 4) .. "...") or ""

    local dialog
    dialog = InputDialog:new{
        title = _("API Token"),
        description = masked ~= "" and (
            _("Current token: ") .. masked
        ) or nil,
        input = "",
        input_hint = _("Enter 16-character token"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local token = dialog:getInputText()
                    if token and token ~= "" then
                        self.settings:saveSetting("token", token)
                        self.settings:flush()
                    end
                    UIManager:close(dialog)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Varbook:showPairingDialog(touchmenu_instance)
    local server_url = self.settings:readSetting("server_url")
    if not server_url or server_url == "" or server_url == "https://" then
        -- Ask for server URL first, then re-call pairing dialog
        UIManager:show(InfoMessage:new{
            text = _("Please set the server URL first."),
        })
        self:showServerURLDialog(touchmenu_instance)
        return
    end

    local dialog
    dialog = InputDialog:new{
        title = _("Pair with code"),
        description = _("Enter the 5-digit code from the web interface."),
        input = "",
        input_hint = "12345",
        input_type = "number",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Pair"),
                is_enter_default = true,
                callback = function()
                    local code = dialog:getInputText()
                    if not code or code == "" or #code ~= 5 then
                        UIManager:show(InfoMessage:new{
                            text = _("Please enter a 5-digit code."),
                        })
                        return
                    end

                    UIManager:close(dialog)

                    if not VarbookAPI then
                        UIManager:show(InfoMessage:new{
                            text = _("Varbook API module not loaded."),
                        })
                        return
                    end

                    local token, err = VarbookAPI.claimPairingCode(server_url, code)
                    if token then
                        self.settings:saveSetting("token", token)
                        self.settings:flush()
                        UIManager:show(InfoMessage:new{
                            text = _("Pairing successful! Token has been saved."),
                        })
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    elseif err == "invalid_code" then
                        UIManager:show(InfoMessage:new{
                            text = _("Invalid or expired pairing code."),
                        })
                    elseif err == "rate_limited" then
                        UIManager:show(InfoMessage:new{
                            text = _("Too many attempts. Please try again later."),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Network error. Please check your connection and server URL."),
                        })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Varbook:showStatus()
    local doc_hash = self:getDocHash()
    local pending = doc_hash and VarbookDB:countUnsynced(doc_hash) or 0
    local total_pending = VarbookDB:countUnsynced()
    local last_sync = self:getLastSyncTimestamp()
    local last_sync_str = last_sync > 0
        and os.date("%Y-%m-%d %H:%M", last_sync)
        or _("Never")

    local configured = self:isConfigured()
    local url = self.settings:readSetting("server_url") or _("Not set")
    local token = self.settings:readSetting("token")
    local token_str = token and token ~= "" and (token:sub(1, 4) .. "...") or _("Not set")

    local text = table.concat({
        _("Server") .. ": " .. url,
        _("Token") .. ": " .. token_str,
        _("Status") .. ": " .. (configured and _("Configured") or _("Not configured")),
        "",
        _("Current book pending") .. ": " .. tostring(pending),
        _("Total pending") .. ": " .. tostring(total_pending),
        _("Last sync") .. ": " .. last_sync_str,
    }, "\n")

    UIManager:show(InfoMessage:new{ text = text })
end

return Varbook

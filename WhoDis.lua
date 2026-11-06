-- WhoDis
-- Appends a guildmate's public guild note to their name in chat:
--     [Bean Sommelier]: hi   ->   [Bean Sommelier(snerf)]: hi
--
-- Design (matches the taint rules the other Forever-era chat addons document):
--   * NEVER replace cf.AddMessage or any Blizzard global -- that taints the secure
--     chat handler. We use hooksecurefunc (post-hook) instead.
--   * The player hyperlink target is never touched, so click / right-click /
--     whisper on a name keeps working. Only the visible text inside [ ] changes.
--   * Blizzard's class colouring is untouched (we add text after the coloured name).
--   * Secret strings (chat lockdown: encounters, M+, PvP, instances) are never
--     inspected or modified.

local ADDON_NAME = ...

local issecretvalue = _G.issecretvalue
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local DEFAULTS = { enabled = true, color = nil }
local db

local notes = {}        -- [name] = cleaned public note (full "Name-Realm" and short "Name")
local noteCount = 0

local function Say(msg)
    print("|cff33ff99WhoDis|r: " .. msg)
end

---------------------------------------------------------------------------
-- Roster cache
---------------------------------------------------------------------------
local function CleanNote(note)
    if type(note) ~= "string" or IsSecret(note) then return nil end
    -- drop colour codes first, then any stray pipe / bracket so the note can't break the link text
    note = note:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", ""):gsub("[%[%]]", "")
    note = note:match("^%s*(.-)%s*$")
    if note == "" then return nil end
    return note
end

local function RebuildCache()
    wipe(notes)
    noteCount = 0
    if not IsInGuild() then return end
    local total = GetNumGuildMembers() or 0
    for i = 1, total do
        -- name, rank, rankIndex, level, class, zone, publicNote, officerNote, ...
        local name, _, _, _, _, _, publicNote = GetGuildRosterInfo(i)
        if type(name) == "string" and not IsSecret(name) then
            local note = CleanNote(publicNote)
            if note then
                notes[name] = note
                local short = name:match("^([^%-]+)")
                if short and not notes[short] then notes[short] = note end
                noteCount = noteCount + 1
            end
        end
    end
end

-- GUILD_ROSTER_UPDATE can fire in bursts on big guilds; coalesce rebuilds.
local rebuildQueued = false
local function QueueRebuild()
    if rebuildQueued then return end
    rebuildQueued = true
    C_Timer.After(1, function()
        rebuildQueued = false
        RebuildCache()
    end)
end

-- GuildRoster() itself fires GUILD_ROSTER_UPDATE and the server rate-limits it,
-- so keep requests throttled (we only rebuild on the event, never request there).
local lastRequest = 0
local function RequestRoster()
    if not IsInGuild() or InCombatLockdown() then return end
    local now = GetTime()
    if now - lastRequest < 15 then return end
    lastRequest = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

local function Lookup(linkName)
    if not linkName then return nil end
    return notes[linkName] or notes[(linkName:match("^([^%-]+)"))]
end

---------------------------------------------------------------------------
-- Text rewrite
---------------------------------------------------------------------------
-- |Hplayer:Name-Realm:lineID:CHATTYPE|h[|cffAABBCCName|r]|h
--  ^ capture 1 (prefix, includes "|h[")       ^ 3 (display)   ^ 4 "]|h"
local PLAYER_LINK = "(|Hplayer:([^:|]+)[^|]*|h%[)(.-)(%]|h)"

-- Zero-width marker (an empty colour span) appended after every note we insert.
-- Chat gets re-fed to us: Ellesmere rebuilds its window from Blizzard's stored
-- lines, and session history replays old lines. The marker lets us recognise a
-- line we already handled, even if the note has since changed, so notes never stack.
local MARK = "|cff010101|r"

local function AddNotes(text)
    return (text:gsub(PLAYER_LINK, function(prefix, name, display, suffix)
        if display:find(MARK, 1, true) then return nil end     -- already applied
        local note = Lookup(name)
        if not note then return nil end                        -- nil keeps the original
        local shown = "(" .. note .. ")"
        if db.color then shown = "|cff" .. db.color .. shown .. "|r" end
        return prefix .. display .. shown .. MARK .. suffix
    end))
end

-- Counters shown by /whodis status, so a hooked frame that can't be rewritten is visible.
local stats = { rewritten = 0, noBuffer = 0, mismatch = 0 }

-- Post-hook on <frame>:AddMessage. By the time it runs, the frame has stored the line
-- in frame.historyBuffer (entry 1 = newest) and layout is still pending, so rewriting
-- the stored string changes what gets drawn while leaving the link data alone.
-- Used for two kinds of frame:
--   * Blizzard's chat frames (ChatFrameN): stock chat, and the invisible layer that
--     serves link clicks underneath Ellesmere's window.
--   * Ellesmere's own message frame per chat window: the one that is actually
--     visible when the EllesmereUI Chat module is on. It is fed a copy of the line
--     taken BEFORE our rewrite, so it has to be rewritten separately.
local function OnAddMessage(frame, text)
    if not db or not db.enabled then return end
    if type(text) ~= "string" or IsSecret(text) then return end
    if not text:find("|Hplayer:", 1, true) then return end

    local out = AddNotes(text)
    if out == text then return end

    local hb = frame.historyBuffer
    local e = hb and hb.GetEntryAtIndex and hb:GetEntryAtIndex(1)
    if not e then
        stats.noBuffer = stats.noBuffer + 1
    elseif type(e.message) == "string" and not IsSecret(e.message) and e.message == text then
        e.message = out
        stats.rewritten = stats.rewritten + 1
        if frame.MarkDisplayDirty then pcall(frame.MarkDisplayDirty, frame) end
    else
        stats.mismatch = stats.mismatch + 1
    end
end

local hooked = {}        -- [frame] = true
local ellesmereDone = {} -- [chat frame] = true once its Ellesmere window is hooked
local numChatHooks, numEllesmereHooks = 0, 0

local function HookFrame(frame)
    if not frame or hooked[frame] or type(frame.AddMessage) ~= "function" then return false end
    hooked[frame] = true
    hooksecurefunc(frame, "AddMessage", OnAddMessage)
    return true
end

-- Identify a message frame by what it can do, not by GetObjectType(): the widget is a
-- Lua-mixin intrinsic and may report a different type name than "ScrollingMessageFrame".
local function LooksLikeMessageFrame(f)
    return (type(f) == "table" or type(f) == "userdata")
       and type(f.AddMessage) == "function"
end

-- Ellesmere keeps per-chat-frame state in EllesmereUI._chatCFD(cf); .bg is the panel
-- its message frame is parented to. Everything here is a plain read of public widget
-- data; nothing is written onto Blizzard's frames.
local function HookEllesmereWindow(cf)
    if ellesmereDone[cf] then return end
    local EUI = _G.EllesmereUI
    local CFD = EUI and EUI._chatCFD
    if type(CFD) ~= "function" then return end
    local d = CFD(cf)
    local bg = d and d.bg
    if not (bg and bg.GetChildren) then return end
    for _, child in ipairs({ bg:GetChildren() }) do
        if child ~= cf and LooksLikeMessageFrame(child) then
            if HookFrame(child) then numEllesmereHooks = numEllesmereHooks + 1 end
            ellesmereDone[cf] = true
        end
    end
end

-- Safe to call repeatedly: already-hooked frames are skipped. Ellesmere creates its
-- windows a moment after login (and for new whisper windows later), so this is also
-- driven by a timer and by window events.
local function HookFrames()
    local names = _G.CHAT_FRAMES
    if type(names) == "table" and #names > 0 then
        for _, name in ipairs(names) do
            local cf = _G[name]
            if HookFrame(cf) then numChatHooks = numChatHooks + 1 end
            if cf then HookEllesmereWindow(cf) end
        end
    else
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local cf = _G["ChatFrame" .. i]
            if HookFrame(cf) then numChatHooks = numChatHooks + 1 end
            if cf then HookEllesmereWindow(cf) end
        end
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_WHODIS1 = "/whodis"
SLASH_WHODIS2 = "/wd"
SlashCmdList["WHODIS"] = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    if cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        Say(db.enabled and "enabled (applies to new messages)." or "disabled.")
    elseif cmd == "refresh" then
        lastRequest = 0
        RequestRoster()
        RebuildCache()
        Say(("cache holds %d guild notes."):format(noteCount))
    elseif cmd == "color" then
        if arg:lower() == "off" or arg == "" then
            db.color = nil
            Say("note colour: default (follows the chat channel colour).")
        elseif arg:match("^%x%x%x%x%x%x$") then
            db.color = arg
            Say("note colour set to " .. arg .. ".")
        else
            Say("usage: /whodis color RRGGBB   (or /whodis color off)")
        end
    elseif cmd == "status" then
        HookFrames()
        Say(("lines rewritten %d, no buffer %d, entry mismatch %d"):format(stats.rewritten, stats.noBuffer, stats.mismatch))
        Say(("%s | %d notes cached | hooked %d chat frame(s), %d EllesmereUI window(s)%s")
            :format(db.enabled and "enabled" or "disabled", noteCount, numChatHooks, numEllesmereHooks,
                    (_G.EllesmereUI and _G.EllesmereUI._chatCFD and numEllesmereHooks == 0)
                        and " - EllesmereUI Chat found but no window hooked yet (try /whodis debug)" or ""))
    elseif cmd == "debug" then
        local cf = _G.ChatFrame1
        local EUI = _G.EllesmereUI
        local CFD = EUI and EUI._chatCFD
        Say("debug: EllesmereUI " .. (EUI and "present" or "absent")
            .. ", _chatCFD " .. type(CFD))
        local d = type(CFD) == "function" and cf and CFD(cf)
        local bg = d and d.bg
        Say("debug: ChatFrame1 panel (bg) " .. (bg and "found" or "NOT found"))
        if bg and bg.GetChildren then
            local kids = { bg:GetChildren() }
            Say("debug: panel has " .. #kids .. " child frame(s):")
            for i, c in ipairs(kids) do
                local otype = c.GetObjectType and c:GetObjectType() or "?"
                local nm = c.GetName and c:GetName() or "(unnamed)"
                Say(("  %d) %s | %s | AddMessage=%s GetNumMessages=%s historyBuffer=%s | hooked=%s%s"):format(
                    i, otype, tostring(nm), type(c.AddMessage), type(c.GetNumMessages),
                    type(c.historyBuffer), tostring(hooked[c] or false), c == cf and " (is ChatFrame1)" or ""))
            end
        end
    elseif cmd == "test" then
        local name = arg ~= "" and arg or UnitName("player")
        local note = Lookup(name)
        Say(note and ("%s -> note \"%s\""):format(name, note)
                  or ("no note cached for %s (cache holds %d notes)."):format(name, noteCount))
        -- Synthetic chat line; goes through the real hook, so you see the end result.
        DEFAULT_CHAT_FRAME:AddMessage(("|Hplayer:%s:0:GUILD|h[|cffffffff%s|r]|h: this is a test line"):format(name, name))
    else
        Say(("%s, %d notes cached. Commands: /whodis on|off | refresh | status | debug | test [name] | color RRGGBB|off")
            :format(db.enabled and "enabled" or "disabled", noteCount))
    end
end

---------------------------------------------------------------------------
-- Login / reload message
---------------------------------------------------------------------------
local function Announce()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = getMeta and getMeta(ADDON_NAME, "Version")
    Say(("%sloaded - guild notes in chat are %s. Type /whodis for commands.")
        :format(version and ("v" .. version .. " ") or "", db.enabled and "|cff00ff00ON|r" or "|cffff4040OFF|r"))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UPDATE_CHAT_WINDOWS")
f:RegisterEvent("PLAYER_GUILD_UPDATE")
f:RegisterEvent("GUILD_ROSTER_UPDATE")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        WhoDisDB = WhoDisDB or {}
        db = WhoDisDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
    elseif event == "PLAYER_LOGIN" then
        HookFrames()
        -- Ellesmere builds its chat windows shortly after login; catch them early,
        -- then keep an eye out for later ones (new whisper windows, pop-outs).
        C_Timer.After(1, HookFrames)
        C_Timer.After(3, HookFrames)
        C_Timer.NewTicker(5, HookFrames)
        C_Timer.NewTicker(60, RequestRoster)
        Announce()
    elseif event == "GUILD_ROSTER_UPDATE" then
        QueueRebuild()
    elseif event == "UPDATE_CHAT_WINDOWS" then
        if db then HookFrames() end
    else -- PLAYER_ENTERING_WORLD / PLAYER_GUILD_UPDATE
        RequestRoster()
        if db then HookFrames() end
    end
end)

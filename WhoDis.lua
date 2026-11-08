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
-- True only for well-formed UTF-8 with no control characters. WoW drops an entire
-- chat line whose text contains a malformed sequence, so a note that fails this is
-- never inserted.
local function IsCleanText(str)
    local i, n = 1, #str
    while i <= n do
        local c = str:byte(i)
        local len
        if c < 0x20 or c == 0x7F then return false          -- control character
        elseif c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else return false end                               -- stray continuation / invalid lead byte
        for k = i + 1, i + len - 1 do
            local cc = str:byte(k)
            if not cc or cc < 0x80 or cc > 0xBF then return false end
        end
        i = i + len
    end
    return true
end

local badNotes, lastBadNote = 0, nil

local function CleanNote(note, who)
    if type(note) ~= "string" or IsSecret(note) then return nil end
    -- drop colour codes first, then any stray pipe / bracket so the note can't break the link text
    note = note:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", ""):gsub("[%[%]]", "")
    -- trim ASCII whitespace only: %s can match bytes inside accented characters on some setups
    note = note:match("^[ \t\r\n]*(.-)[ \t\r\n]*$")
    if note == "" then return nil end
    if not IsCleanText(note) then
        badNotes = badNotes + 1
        lastBadNote = { who = who, raw = note }
        return nil
    end
    return note
end

-- Show any byte outside printable ASCII as <HH>, so odd notes are visible in /whodis log.
local function ShowBytes(str)
    return (str:gsub("[^\32-\126]", function(ch) return ("<%02X>"):format(ch:byte()) end))
end

local rosterSeen, lastRebuildAt = 0, nil
local function RebuildCache()
    wipe(notes)
    noteCount = 0
    if not IsInGuild() then return end
    local total = GetNumGuildMembers() or 0
    rosterSeen, lastRebuildAt = total, GetTime()
    badNotes, lastBadNote = 0, nil
    for i = 1, total do
        -- name, rank, rankIndex, level, class, zone, publicNote, officerNote, ...
        local name, _, _, _, _, _, publicNote = GetGuildRosterInfo(i)
        if type(name) == "string" and not IsSecret(name) then
            local note = CleanNote(publicNote, name)
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

-- Post-hook on <frame>:AddMessage. By the time it runs, the frame has stored the line;
-- WhoDis then edits the stored copy (see Rewrite) so only the visible name text
-- changes and the link data is left alone. Used for two kinds of frame:
--   * Blizzard's chat frames (ChatFrameN): stock chat, and the invisible layer that
--     serves link clicks underneath Ellesmere's window.
--   * Ellesmere's own message frame per chat window: the one that is actually
--     visible when the EllesmereUI Chat module is on. It is fed a copy of the line
--     taken BEFORE our edit, so it has to be edited separately.

-- Recent rewrites, for /whodis log: what each line looked like before and after.
local LOG_MAX = 12
local rewriteLog = {}
local function LogRewrite(frame, before, after, result)
    local name = frame.GetName and frame:GetName() or "EllesmereUI window"
    table.insert(rewriteLog, 1, { frame = tostring(name), before = before, after = after, result = result })
    rewriteLog[LOG_MAX + 1] = nil
end

-- Edits are queued and applied one frame later with the frame's own
-- TransformMessages API, never by writing into its history buffer:
--   * other chat addons (e.g. Better Forever Chat) edit the same line right after
--     Blizzard stores it, and find it by its EXACT original text. Running after
--     them keeps their changes (level, class colour) and adds the note on top.
--   * the line is found by its player link, which carries Blizzard's per-message
--     line ID, so another addon's edits can't hide it from us.
stats.errors = 0
local lastError, lastErrorLine, errorAnnounced
local pending, flushQueued = {}, false     -- [frame] = { [link opening] = true }

local function TransformOne(frame, message)
    local ok, out = pcall(AddNotes, message)
    if not ok then
        stats.errors = stats.errors + 1
        return message
    end
    if out ~= message then
        stats.rewritten = stats.rewritten + 1
        LogRewrite(frame, message, out, "rewritten")
    end
    return out
end

local function Flush()
    flushQueued = false
    for frame, links in pairs(pending) do
        pending[frame] = nil
        if db and db.enabled then
            frame:TransformMessages(function(message)
                if type(message) ~= "string" or IsSecret(message) then return false end
                for open in pairs(links) do
                    if message:find(open, 1, true) then return true end
                end
                return false
            end, function(message, r, g, b, ...)
                return TransformOne(frame, message), r, g, b, ...
            end)
        end
    end
end

local function Rewrite(frame, text)
    if not db or not db.enabled then return end
    if type(text) ~= "string" or IsSecret(text) then return end
    if not text:find("|Hplayer:", 1, true) then return end

    -- Which player links in this line belong to someone with a note?
    local links
    for open, name in text:gmatch("(|Hplayer:([^:|]+)[^|]*|h)") do
        if Lookup(name) then
            links = links or {}
            links[open] = true
        end
    end
    if not links then return end

    if type(frame.TransformMessages) == "function" then
        local set = pending[frame] or {}
        pending[frame] = set
        for open in pairs(links) do set[open] = true end
        if not flushQueued then
            flushQueued = true
            C_Timer.After(0, function()
                local ok, err = pcall(Flush)
                if not ok then
                    flushQueued = false
                    wipe(pending)
                    stats.errors = stats.errors + 1
                    lastError, lastErrorLine = tostring(err), "(while applying queued notes)"
                end
            end)
        end
        return
    end

    -- Fallback for a frame without TransformMessages: edit the newest stored entry,
    -- only if it is still exactly the line we were handed.
    local out = AddNotes(text)
    if out == text then return end
    local hb = frame.historyBuffer
    local e = hb and hb.GetEntryAtIndex and hb:GetEntryAtIndex(1)
    if not e then
        stats.noBuffer = stats.noBuffer + 1
        LogRewrite(frame, text, out, "no buffer")
    elseif type(e.message) == "string" and not IsSecret(e.message) and e.message == text then
        e.message = out
        stats.rewritten = stats.rewritten + 1
        LogRewrite(frame, text, out, "rewritten (fallback)")
    else
        stats.mismatch = stats.mismatch + 1
        LogRewrite(frame, text, out, "entry mismatch")
    end
end

-- Never let an error escape this hook: with EllesmereUI Chat, Ellesmere's own hook
-- runs after ours in the same call, and an escaped error would stop it from
-- copying the line into its window. Record the first error instead.
local function OnAddMessage(frame, text)
    local ok, err = pcall(Rewrite, frame, text)
    if not ok then
        stats.errors = stats.errors + 1
        lastError = tostring(err)
        lastErrorLine = type(text) == "string" and not IsSecret(text) and text or "(not a plain string)"
        if not errorAnnounced then
            errorAnnounced = true
            -- printing from inside a chat hook would re-enter chat; do it next frame
            C_Timer.After(0, function()
                print("|cff33ff99WhoDis|r: hit an error on a chat line (the line itself was left alone). Type /whodis errors for details.")
            end)
        end
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
-- /whodis selftest: checks, in this client, whether non-ASCII note text can
-- make a chat line vanish. Lines are built exactly the way WhoDis builds them,
-- but added directly so WhoDis's own note cleaning is NOT in the way.
---------------------------------------------------------------------------
local SELFTEST_CASES = {
    { "snerf",                          "plain ASCII note" },
    { "alt de Zo\195\171 \195\160",     "accented letters, valid UTF-8" },
    { "\230\188\162\229\173\151",       "CJK, valid UTF-8" },
    { "\240\159\152\128 hi",            "emoji, 4-byte UTF-8" },
    { "alt de Zo\195",                  "accented letter cut in half, invalid UTF-8" },
    { "main \160",                      "stray byte, invalid UTF-8" },
    { "bad\1note",                      "control character" },
}

local function RunSelfTest(realName)
    -- 1) The old trim used %s. Which bytes does this client's Lua call "space"?
    local spaceBytes = {}
    for b = 128, 255 do
        if string.char(b):find("^%s$") then spaceBytes[#spaceBytes + 1] = ("%02X"):format(b) end
    end
    local sample = "alt de Zo\195\171 \195\160"            -- "alt de Zoë à", ends in an accented letter
    local oldTrim = sample:match("^%s*(.-)%s*$")
    Say("selftest 1 - high bytes Lua treats as spaces: " .. (#spaceBytes > 0 and table.concat(spaceBytes, " ") or "none"))
    Say(("selftest 1 - old trim on %s gives %s: %s"):format(ShowBytes(sample), ShowBytes(oldTrim),
        oldTrim == sample and "accents survive" or "|cffff4040accented letter was CUT (invalid text)|r"))

    -- 2) Which kinds of note text does the chat window draw?
    Say(("selftest 2 - printing %d numbered lines. A missing number = a line the game would not draw:"):format(#SELFTEST_CASES))
    for i, c in ipairs(SELFTEST_CASES) do
        Say(("   %d = %s"):format(i, c[2]))
    end
    local frame = DEFAULT_CHAT_FRAME
    local me = UnitName("player") or "You"
    for i, c in ipairs(SELFTEST_CASES) do
        -- same shape as a real rewritten line: class-coloured name, (note), marker
        local line = "|Hplayer:" .. me .. ":0:GUILD|h[|cff8788ee" .. me .. "|r(" .. c[1] .. ")" .. MARK
                     .. "]|h: selftest line " .. i
        local ok, err = pcall(frame.AddMessage, frame, line)
        if not ok then Say(("   line %d raised a Lua error: %s"):format(i, tostring(err))) end
    end
    -- 3) The real edit path: Blizzard stores the plain line, WhoDis's hook edits the
    --    stored copy. Uses dummy names with temporary notes (or a real player's note).
    local editCases = {
        { "snerf",                       "plain note" },
        { "alt de Zo\195\171 \195\160",   "accented note" },
        { "a much longer guild note text", "long note" },
    }
    if realName and realName ~= "" then
        local n = Lookup(realName)
        editCases[#editCases + 1] = { n, ("%s's real note"):format(realName) }
    end
    local first = #SELFTEST_CASES + 1
    Say(("selftest 3 - real edit path, lines %d to %d. Each should show its (note):")
        :format(first, first + #editCases - 1))
    for k, c in ipairs(editCases) do
        local i = first + k - 1
        Say(("   %d = %s%s"):format(i, c[2], c[1] and "" or " (no note cached for that name!)"))
    end
    if not db.enabled then Say("   |cffff4040WhoDis is off (/whodis on), so part 3 will show no notes.|r") end
    local info = ChatTypeInfo and ChatTypeInfo.GUILD
    local r, g, b = info and info.r, info and info.g, info and info.b
    local injected = {}
    for k, c in ipairs(editCases) do
        local i = first + k - 1
        local dummy = "WhoDisTest" .. i
        if c[1] then notes[dummy] = c[1]; injected[#injected + 1] = dummy end
        local plain = "|Hplayer:" .. dummy .. ":0:GUILD|h[|cff8788ee" .. dummy .. "|r]|h: selftest line " .. i
        local ok, err = pcall(frame.AddMessage, frame, plain, r, g, b)
        if not ok then Say(("   line %d raised a Lua error: %s"):format(i, tostring(err))) end
    end
    C_Timer.After(0.5, function()   -- after WhoDis's queued edits have been applied
        for _, dummy in ipairs(injected) do notes[dummy] = nil end
        Say(("selftest done - lines 1 to %d should all be above; %d onward should show their (note).")
            :format(first + #editCases - 1, first))
    end)
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
    elseif cmd == "log" then
        if #rewriteLog == 0 then
            Say("no lines rewritten yet this session.")
        else
            Say(("last %d rewritten line(s), newest first (raw codes shown):"):format(#rewriteLog))
            for i, r in ipairs(rewriteLog) do
                print(("|cffffd200%d) %s, %s|r"):format(i, r.frame, r.result))
                print("   before: " .. ShowBytes(r.before:gsub("|", "||")))
                print("   after:  " .. ShowBytes(r.after:gsub("|", "||")))
            end
        end
    elseif cmd == "errors" then
        Say(("%d error(s) this session."):format(stats.errors))
        if lastError then
            print("   error: " .. lastError:gsub("|", "||"))
            print("   line:  " .. lastErrorLine:gsub("|", "||"))
        end
    elseif cmd == "selftest" then
        RunSelfTest(arg)
    elseif cmd == "status" then
        HookFrames()
        Say(("roster: %d members seen, %d notes cached, cache rebuilt %s")
            :format(rosterSeen, noteCount, lastRebuildAt and ("%ds ago"):format(GetTime() - lastRebuildAt) or "never"))
        if badNotes > 0 then
            Say(("%d guild note(s) skipped as malformed text, e.g. %s: %s")
                :format(badNotes, tostring(lastBadNote.who), ShowBytes(lastBadNote.raw)))
        end
        Say(("lines rewritten %d, no buffer %d, entry mismatch %d, errors %d"):format(stats.rewritten, stats.noBuffer, stats.mismatch, stats.errors))
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
        Say(("%s, %d notes cached. Commands: /whodis on|off | refresh | status | log | errors | selftest [name] | debug | test [name] | color RRGGBB|off")
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

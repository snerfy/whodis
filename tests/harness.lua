-- Test harness for WhoDis: a small mock of the WoW client, enough to load WhoDis.lua
-- and drive chat lines through it. Run the suite from the repo root: bash tests/run.sh
--
-- Written for Lua 5.1 (what WoW uses); also runs on 5.4.

local H = { passes = 0, failures = 0 }
local unpack = unpack or table.unpack

local WHODIS_PATH = os.getenv("WHODIS_PATH") or "WhoDis.lua"
local VERBOSE = os.getenv("VERBOSE")
local realPrint = print

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------
function H.check(name, cond, detail)
    if cond then
        H.passes = H.passes + 1
        realPrint("  ok   " .. name)
    else
        H.failures = H.failures + 1
        realPrint("  FAIL " .. name .. (detail ~= nil and ("\n         got: " .. tostring(detail)) or ""))
    end
end

function H.section(title) realPrint("-- " .. title) end

function H.finish()
    realPrint(("   %d passed, %d failed"):format(H.passes, H.failures))
    if H.failures > 0 then os.exit(1) end
end

-- plain-text find (no Lua pattern magic), and occurrence count
function H.has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
function H.count(s, sub)
    local n, i = 0, 1
    while true do
        local a, b = s:find(sub, i, true)
        if not a then return n end
        n, i = n + 1, b + 1
    end
end

-- ---------------------------------------------------------------------------
-- Chat line builders
-- ---------------------------------------------------------------------------
H.MARK = "|cff010101|r"   -- WhoDis's zero-width "already handled" marker

-- A guild line the way Blizzard formats it: class-coloured name inside the link.
function H.GuildLine(name, display, body, lineID, color)
    return ("|Hplayer:%s:%d:GUILD|h[|cff%s%s|r]|h: %s")
        :format(name, lineID or 1, color or "8788ee", display, body or "hi")
end

-- A secret (protected) value, as the 12.x client hands out in restricted content.
function H.Secret(text) return { secret = true, text = text } end

-- ---------------------------------------------------------------------------
-- Message frames (Blizzard chat frames, Ellesmere's window, ...)
-- ---------------------------------------------------------------------------
function H.NewMessageFrame(name, opts)
    opts = opts or {}
    local f = { name = name, dirty = 0, transforms = 0 }
    local entries = {}              -- newest first, like Blizzard's historyBuffer
    f.entries = entries
    f.historyBuffer = { GetEntryAtIndex = function(_, i) return entries[i] end }
    function f:AddMessage(text, r, g, b, id, access, typeID, event, eventArgs)
        table.insert(entries, 1, { message = text, r = r, g = g, b = b, event = event, args = eventArgs })
    end
    if not opts.noTransform then
        -- mirrors ScrollingMessageFrame:TransformMessages(predicate, transform)
        function f:TransformMessages(predicate, transform)
            self.transforms = self.transforms + 1
            for _, e in ipairs(entries) do
                if predicate(e.message, e.r, e.g, e.b, nil, nil, nil, e.event, e.args) then
                    local m, r, g, b = transform(e.message, e.r, e.g, e.b, nil, nil, nil, e.event, e.args)
                    e.message, e.r, e.g, e.b = m, r, g, b
                end
            end
        end
    end
    function f:MarkDisplayDirty() self.dirty = self.dirty + 1 end
    function f:GetName() return name end
    function f:GetObjectType() return opts.objectType or "ScrollingMessageFrame" end
    function f:GetNumMessages() return #entries end
    function f:Clear() for i = #entries, 1, -1 do entries[i] = nil end end
    function f:newest() return entries[1] and entries[1].message end
    function f:lines()
        local out = {}
        for i = #entries, 1, -1 do out[#out + 1] = entries[i].message end
        return out
    end
    return f
end

-- ---------------------------------------------------------------------------
-- A fresh client: globals reset, WhoDis loaded, events available.
-- opts.roster       = { {"Name-Realm", "public note"}, ... }
-- opts.frames       = number of Blizzard chat frames (default 1)
-- opts.noTransform  = Blizzard chat frames lack TransformMessages
-- opts.beforeLoad   = function(W) run before WhoDis loads (install other addons)
-- ---------------------------------------------------------------------------
function H.Start(opts)
    opts = opts or {}
    local W = { printed = {}, hookCount = 0, tickers = {} }
    local queue = {}

    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.issecretvalue = function(v) return type(v) == "table" and v.secret == true end

    local roster = opts.roster or {
        { "Bean Sommelier-Mankrik", "snerf" },
        { "Lock Guy-Mankrik", "warlock main" },
        { "NoNote-Mankrik", "" },
        { "Remote-OtherRealm", "cross realm" },
    }
    W.roster = roster
    _G.IsInGuild = function() return true end
    _G.GetNumGuildMembers = function() return #roster, #roster end
    _G.GetGuildRosterInfo = function(i)
        local r = roster[i]
        -- name, rank, rankIndex, level, class, zone, publicNote, officerNote, ...
        return r[1], "Member", 1, 60, "Warlock", "Zone", r[2], "", true, 0, "WARLOCK"
    end
    _G.InCombatLockdown = function() return false end
    local clock = 0
    _G.GetTime = function() clock = clock + 1; return clock end
    _G.C_Timer = {
        After = function(_, fn)
            if W.timerErrors then error("simulated timer failure") end
            queue[#queue + 1] = fn
        end,
        NewTicker = function(_, fn) W.tickers[#W.tickers + 1] = fn end,
    }
    _G.C_GuildInfo = { GuildRoster = function() end }
    _G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
    _G.GetAddOnMetadata = nil
    _G.UnitName = function() return "Bean Sommelier" end
    _G.ChatTypeInfo = { GUILD = { r = 0.25, g = 1, b = 0.25 } }
    _G.SlashCmdList = {}
    _G.SLASH_WHODIS1, _G.SLASH_WHODIS2 = nil, nil
    _G.WhoDisDB = opts.savedVariables
    _G.EllesmereUI, _G.Chattynator = nil, nil

    -- Blizzard chat frames
    _G.CHAT_FRAMES = {}
    W.frames = {}
    for i = 1, (opts.frames or 1) do
        local f = H.NewMessageFrame("ChatFrame" .. i, { noTransform = opts.noTransform })
        _G["ChatFrame" .. i] = f
        _G.CHAT_FRAMES[i] = "ChatFrame" .. i
        W.frames[i] = f
    end
    W.cf = W.frames[1]
    _G.DEFAULT_CHAT_FRAME = W.cf
    _G.NUM_CHAT_WINDOWS = opts.frames or 1

    -- hooksecurefunc: original runs first, then the hook; a hook error propagates.
    _G.hooksecurefunc = function(tbl, name, fn)
        if type(tbl) == "string" then tbl, name, fn = _G, tbl, name end
        W.hookCount = W.hookCount + 1
        local orig = tbl[name]
        tbl[name] = function(...)
            local results = { orig(...) }
            fn(...)
            return unpack(results)
        end
    end

    local handler
    _G.CreateFrame = function()
        return {
            RegisterEvent = function() end,
            SetScript = function(_, _, fn) handler = fn end,
        }
    end

    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, " ")
        W.printed[#W.printed + 1] = line
        if VERBOSE then realPrint("     | " .. line) end
    end

    function W.nextFrame()
        local q = queue
        queue = {}
        for _, fn in ipairs(q) do fn() end
    end
    function W.event(name, ...) handler(nil, name, ...) end
    function W.slash(msg) _G.SlashCmdList.WHODIS(msg) end
    function W.output() return table.concat(W.printed, "\n") end
    function W.clearOutput() W.printed = {} end

    -- Send a chat line into a Blizzard chat frame the way the chat handler does,
    -- then let the next frame run (WhoDis applies notes one frame later).
    W.lineID = 100
    function W.say(frame, text, event, eventArgs)
        local ok, err = pcall(frame.AddMessage, frame, text, 0.25, 1, 0.25, nil, nil, nil,
                              event or "CHAT_MSG_GUILD", eventArgs or {})
        W.nextFrame()
        return ok, err
    end
    function W.guild(name, display, body)
        W.lineID = W.lineID + 1
        local text = H.GuildLine(name, display, body, W.lineID)
        local ok, err = W.say(W.cf, text)
        return W.cf:newest(), ok, err
    end

    if opts.beforeLoad then opts.beforeLoad(W) end

    local chunk = assert(loadfile(WHODIS_PATH))
    chunk("WhoDis")
    W.event("ADDON_LOADED", "WhoDis")
    if opts.afterAddonLoaded then opts.afterAddonLoaded(W) end
    W.event("PLAYER_LOGIN")
    W.event("GUILD_ROSTER_UPDATE")
    W.nextFrame()                  -- roster rebuild + first delayed hook passes
    W.nextFrame()
    for _, t in ipairs(W.tickers) do t() end
    if opts.afterLogin then opts.afterLogin(W) end
    W.clearOutput()
    return W
end

return H

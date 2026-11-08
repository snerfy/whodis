-- EllesmereUI Chat: Blizzard's chat frame stays as an invisible layer, and Ellesmere
-- copies each line (as it was handed to AddMessage) into its own visible window,
-- a child of the panel it keeps in EllesmereUI._chatCFD(cf).bg.
local H = dofile("tests/harness.lua")
local MARK = H.MARK

-- opts.order: "before" = Ellesmere's hook installed before WhoDis's, "after" = later
--             (the real order: Ellesmere integrates its frames after login)
-- opts.objectType: what the window reports from GetObjectType()
local function StartEllesmere(opts)
    local win = H.NewMessageFrame("EllesmereWindow", { objectType = opts.objectType })
    local function installTail(W)
        hooksecurefunc(W.cf, "AddMessage", function(_, text, r, g, b)
            win:AddMessage(text, r, g, b)
        end)
    end
    local W = H.Start({
        beforeLoad = function(W)
            local editBox = { GetObjectType = function() return "EditBox" end }
            local plain = { GetObjectType = function() return "Frame" end }
            W.editBox, W.plain = editBox, plain
            local bg = { GetChildren = function() return W.cf, plain, editBox, win end }
            _G.EllesmereUI = { _chatCFD = function() return { bg = bg } end }
            if opts.order == "before" then installTail(W) end
        end,
        afterLogin = function(W)
            if opts.order == "after" then installTail(W) end
        end,
    })
    W.win = win
    return W
end

for _, order in ipairs({ "before", "after" }) do
    for _, objectType in ipairs({ "ScrollingMessageFrame", "Frame" }) do
        H.section(("Ellesmere hooked %s WhoDis, window reports %q"):format(order, objectType))
        local W = StartEllesmere({ order = order, objectType = objectType })
        W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "hello")
        local visible, hidden = W.win:newest(), W.cf:newest()
        H.check("Ellesmere's visible window shows the note", H.has(visible, "(snerf)"), visible)
        H.check("Blizzard's hidden layer has the identical text (click areas line up)",
            visible == hidden, tostring(visible) .. "  vs  " .. tostring(hidden))
        W.slash("status")
        H.check("/whodis status reports one Ellesmere window",
            H.has(W.output(), "1 EllesmereUI window(s)"), W.output())
    end
end

H.section("Ellesmere rebuilds and session replays don't stack notes")
do
    local W = StartEllesmere({ order = "after" })
    W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "first")
    W.guild("Lock Guy-Mankrik", "Lock Guy", "second")
    -- Ellesmere rebuild: clear its window and re-feed Blizzard's stored lines
    W.win:Clear()
    for _, l in ipairs(W.cf:lines()) do W.win:AddMessage(l) end
    W.nextFrame()
    local lines = W.win:lines()
    H.check("rebuilt line keeps exactly one note", H.count(lines[1], "(snerf)") == 1, lines[1])
    -- the note changes, then another rebuild
    W.roster[1][2] = "new note"
    W.event("GUILD_ROSTER_UPDATE"); W.nextFrame()
    W.win:Clear()
    for _, l in ipairs(W.cf:lines()) do W.win:AddMessage(l) end
    W.nextFrame()
    lines = W.win:lines()
    H.check("a changed note doesn't stack on an old line",
        not H.has(lines[1], "(new note)") and H.count(lines[1], "(snerf)") == 1, lines[1])
    -- session history replays an already-decorated line
    W.win:AddMessage(lines[1]); W.nextFrame()
    H.check("a replayed line is not doubled", H.count(W.win:newest(), "(snerf)") == 1, W.win:newest())
end

H.section("an error in WhoDis never stops Ellesmere receiving the line")
do
    local W = StartEllesmere({ order = "after" })
    W.timerErrors = true                       -- make WhoDis's hook fail
    local ok = W.say(W.cf, H.GuildLine("Bean Sommelier-Mankrik", "Bean Sommelier", "still here", 500))
    W.timerErrors = false
    H.check("no error escaped into the chat handler", ok)
    H.check("Ellesmere's window still got the line", H.has(W.win:newest(), "still here"), W.win:newest())
    W.slash("errors")
    H.check("/whodis errors reports it", H.has(W.output(), "1 error(s)"), W.output())
end

H.section("non-message frames on Ellesmere's panel are ignored")
do
    local W = StartEllesmere({ order = "after" })
    H.check("the edit box and plain frames on the panel are not hooked",
        W.editBox.AddMessage == nil and W.plain.AddMessage == nil)
    -- 3 = WhoDis on Blizzard's frame + WhoDis on Ellesmere's window + Ellesmere's own hook
    H.check("WhoDis hooked exactly Blizzard's frame and Ellesmere's window", W.hookCount == 3, W.hookCount)
end

H.finish()

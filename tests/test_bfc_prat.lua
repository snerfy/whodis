-- Better Forever Chat and Prat-3.0 both work on Blizzard's chat frames.
--
-- Better Forever Chat: after Blizzard stores a line, it finds that line again by its
-- EXACT original text (plus the same event and event-argument table) and rewrites it
-- through TransformMessages, adding the sender's level and class colour.
--
-- Prat-3.0: replaces the chat frames' message handler and builds the whole line itself
-- (brackets OUTSIDE the player link, level inside it), then hands it to AddMessage.
local H = dofile("tests/harness.lua")

local BADGE = "|cffffff00[60]|r "

-- Behaves like Better Forever Chat's safe-mode post-hook.
local function InstallBFC(W)
    hooksecurefunc(W.cf, "AddMessage", function(frame, text, r, g, b, id, access, typeID, event, eventArgs)
        frame:TransformMessages(function(message, _, _, _, ...)
            local storedEvent, storedArgs = select(4, ...), select(5, ...)
            return message == text and storedEvent == event and storedArgs == eventArgs
        end, function(message, rr, gg, bb, ...)
            local decorated = message:gsub("(|Hplayer:[^|]*|h)", BADGE .. "%1", 1)
            return decorated, rr, gg, bb, ...
        end)
    end)
end

for _, order in ipairs({ "before", "after" }) do
    H.section(("Better Forever Chat hooked %s WhoDis"):format(order))
    local W = H.Start({
        beforeLoad = function(W) if order == "before" then InstallBFC(W) end end,
        afterLogin = function(W) if order == "after" then InstallBFC(W) end end,
    })
    local line = W.guild("Lock Guy-Mankrik", "Lock Guy", "hi")
    H.check("BFC's level badge is kept", H.has(line, BADGE .. "|Hplayer:"), line)
    H.check("WhoDis's note is added", H.has(line, "(warlock main)"), line)
    H.check("note added once", H.count(line, "(warlock main)") == 1, line)
    local second = W.guild("Lock Guy-Mankrik", "Lock Guy", "again")
    H.check("works for every line, not just the first", H.has(second, BADGE) and H.has(second, "(warlock main)"), second)
end

-- Builds a guild line the way Prat does.
local function PratLine(name, display, lineID, style)
    local open, close = "|cffaaaaaa[|r", "|cffaaaaaa]|r"          -- brackets colour-wrapped by default
    if style == "Angled" then open, close = "|cffaaaaaa<|r", "|cffaaaaaa>|r" end
    if style == "None" then open, close = "", "" end
    return ("%s|Hplayer:%s:%d:GUILD|h|cff40c04060|r:|cff8788ee%s|r|h%s: hi")
        :format(open, name, lineID, display, close)
end

for _, style in ipairs({ "Square", "Angled", "None" }) do
    H.section(("Prat-3.0, %s brackets"):format(style))
    local W = H.Start()
    W.say(W.cf, PratLine("Lock Guy-Mankrik", "Lock Guy", 300, style))
    local line = W.cf:newest()
    H.check("note goes after the name inside Prat's link (so inside its brackets)",
        H.has(line, "|cff8788eeLock Guy|r (warlock main)" .. H.MARK .. "|h"), line)
    H.check("Prat's level stays in front", H.has(line, "|h|cff40c04060|r:"), line)
end

H.section("Prat-3.0 together with Better Forever Chat")
do
    local W = H.Start({ afterLogin = InstallBFC })
    W.say(W.cf, PratLine("Lock Guy-Mankrik", "Lock Guy", 301, "Square"))
    local line = W.cf:newest()
    H.check("BFC's badge and WhoDis's note are both present",
        H.has(line, BADGE) and H.has(line, "(warlock main)"), line)
end

H.finish()

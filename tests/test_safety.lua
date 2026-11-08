-- Things that must never break chat: odd guild notes, protected (secret) values,
-- and every slash command.
local H = dofile("tests/harness.lua")

H.section("guild notes are cleaned before use")
do
    local W = H.Start({ roster = {
        { "Accent-Mankrik", "  alt de Zo\195\171 \195\160 " },   -- valid UTF-8 with spaces around
        { "Stray-Mankrik", "main \160" },                         -- lone continuation byte: invalid
        { "Cut-Mankrik", "alt de Zo\195" },                       -- accented letter cut in half
        { "Ctrl-Mankrik", "bad\1note" },                          -- control character
        { "Codes-Mankrik", "|cffff0000red|r [x] |Hitem:1|h" },   -- escape codes and brackets
        { "Blank-Mankrik", "    " },
    } })
    local accent = W.guild("Accent-Mankrik", "Accent", "x")
    H.check("accented note is used, trimmed, accents intact",
        H.has(accent, " (alt de Zo\195\171 \195\160)" .. H.MARK .. "]"), accent)
    for _, who in ipairs({ "Stray", "Cut", "Ctrl" }) do
        local line = W.guild(who .. "-Mankrik", who, "x")
        H.check(who .. ": malformed note is refused, line untouched", not H.has(line, "("), line)
    end
    local codes = W.guild("Codes-Mankrik", "Codes", "x")
    H.check("escape codes and brackets are stripped from notes",
        H.has(codes, " (red x Hitem:1h)" .. H.MARK .. "]"), codes)
    local blank = W.guild("Blank-Mankrik", "Blank", "x")
    H.check("whitespace-only note is ignored", not H.has(blank, "("), blank)
    W.slash("status")
    H.check("/whodis status names a refused note", H.has(W.output(), "skipped as malformed text"), W.output())
end

H.section("protected (secret) values are never touched")
do
    local W = H.Start({ roster = { { "Bean Sommelier-Mankrik", H.Secret("snerf") } } })
    local line = W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "x")
    H.check("a secret note value is not used", not H.has(line, "("), line)
    local ok = W.say(W.cf, H.Secret("protected chat line"))
    H.check("a secret chat line passes through without an error", ok)
    H.check("and is left exactly as it was", type(W.cf:newest()) == "table" and W.cf:newest().secret)
end

H.section("every slash command runs without errors")
do
    local W = H.Start()
    W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "x")
    for _, cmd in ipairs({ "", "status", "log", "errors", "debug", "refresh", "test", "test Bean Sommelier",
                           "color 66ccff", "color zzz", "color off", "off", "on", "nonsense" }) do
        local ok, err = pcall(W.slash, cmd)
        W.nextFrame()
        H.check(("/whodis %s"):format(cmd), ok, err)
    end
end

H.section("/whodis selftest")
do
    local W = H.Start()
    local before = #W.cf:lines()
    local ok, err = pcall(W.slash, "selftest Lock Guy")
    for _ = 1, 3 do W.nextFrame() end
    H.check("runs without errors", ok, err)
    local added, withNotes = 0, 0
    for _, l in ipairs(W.cf:lines()) do
        if H.has(l, "selftest line") then
            added = added + 1
            if H.has(l, " (") then withNotes = withNotes + 1 end
        end
    end
    H.check("prints 11 numbered test lines (7 text cases + 4 edit-path cases)", added == 11, added)
    H.check("all 11 show a note", withNotes == 11, withNotes)
    H.check("temporary test notes are removed afterwards",
        not H.has(select(1, W.guild("WhoDisTest8", "WhoDisTest8", "x")), "("))
end

H.finish()

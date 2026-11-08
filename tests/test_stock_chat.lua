-- Blizzard's default chat frames, no other chat addon.
local H = dofile("tests/harness.lua")
local MARK = H.MARK

H.section("stock chat: note added to guild lines")
do
    local W = H.Start()
    local line = W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "hello")
    H.check("note appears after the name, inside the brackets, with a space",
        H.has(line, "[|cff8788eeBean Sommelier|r (snerf)" .. MARK .. "]"), line)
    H.check("player link target is unchanged (click/whisper still work)",
        H.has(line, "|Hplayer:Bean Sommelier-Mankrik:101:GUILD|h["), line)
    H.check("class colour on the name is kept", H.has(line, "|cff8788eeBean Sommelier|r"), line)
    H.check("message body is unchanged", H.has(line, "]|h: hello"), line)

    local plain = W.guild("NoNote-Mankrik", "NoNote", "x")
    H.check("player without a note is left untouched", not H.has(plain, "("), plain)

    local stranger = W.guild("Stranger-Mankrik", "Stranger", "x")
    H.check("non-guild player is left untouched", not H.has(stranger, "("), stranger)

    local remote = W.guild("Remote-OtherRealm", "Remote", "x")
    H.check("cross-realm guildmate gets their note", H.has(remote, "(cross realm)"), remote)

    W.say(W.cf, "|Hplayer:Bean Sommelier:5:SAY|h[Bean Sommelier]|h says hi")
    H.check("link without a realm suffix is matched by short name",
        H.has(W.cf:newest(), "[Bean Sommelier (snerf)" .. MARK .. "]"), W.cf:newest())

    W.say(W.cf, "|Hplayer:Bean Sommelier:1|h[Bean Sommelier]|h invited |Hplayer:Remote-OtherRealm:2|h[Remote]|h.")
    local both = W.cf:newest()
    H.check("every player link in a line gets its note",
        H.has(both, "(snerf)") and H.has(both, "(cross realm)"), both)

    W.say(W.cf, "Plain system text [not a link]")
    H.check("lines without player links are untouched", W.cf:newest() == "Plain system text [not a link]")

    H.check("no forced redraw on Blizzard's frame (taint)", W.cf.dirty == 0, W.cf.dirty)
end

H.section("stock chat: lines are never edited twice")
do
    local W = H.Start()
    W.say(W.cf, "|Hplayer:Bean Sommelier-Mankrik:7:GUILD|h[Bean Sommelier (snerf)" .. MARK .. "]|h: again")
    H.check("an already-marked line is not given a second note",
        H.count(W.cf:newest(), "(snerf)") == 1, W.cf:newest())
    W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "one")
    W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "two")
    local total = 0
    for _, l in ipairs(W.cf:lines()) do total = total + H.count(l, "(snerf)") end
    H.check("later lines from the same person don't re-edit earlier ones", total == 3, total)
end

H.section("stock chat: settings")
do
    local W = H.Start()
    W.slash("off")
    local off = W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "x")
    H.check("/whodis off stops notes", not H.has(off, "(snerf)"), off)
    W.slash("on")
    local on = W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "x")
    H.check("/whodis on brings them back", H.has(on, "(snerf)"), on)
    W.slash("color 66ccff")
    local coloured = W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "x")
    H.check("/whodis color wraps the note in that colour",
        H.has(coloured, " |cff66ccff(snerf)|r" .. MARK .. "]"), coloured)
    W.slash("color off")
end

H.section("stock chat: defaults and saved settings")
do
    local W = H.Start()
    H.check("enabled by default on a fresh install", _G.WhoDisDB.enabled == true)
    local W2 = H.Start({ savedVariables = { enabled = false } })
    local line = W2.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "x")
    H.check("a saved 'off' setting is respected", not H.has(line, "(snerf)"), line)
end

H.section("stock chat: no direct writes when TransformMessages is missing")
do
    local W = H.Start({ noTransform = true })
    local line = W.guild("Bean Sommelier-Mankrik", "Bean Sommelier", "x")
    H.check("the line is left exactly as Blizzard sent it", not H.has(line, "(snerf)"), line)
end

H.section("stock chat: whisper windows opened later")
do
    local W = H.Start()
    local w = H.NewMessageFrame("ChatFrame11")
    _G.ChatFrame11 = w
    _G.CHAT_FRAMES[#_G.CHAT_FRAMES + 1] = "ChatFrame11"
    W.event("UPDATE_CHAT_WINDOWS")
    W.say(w, "|Hplayer:Bean Sommelier-Mankrik:9:WHISPER|h[Bean Sommelier]|h whispers: psst", "CHAT_MSG_WHISPER")
    H.check("a new whisper window is hooked and gets notes", H.has(w:newest(), "(snerf)"), w:newest())
end

H.finish()

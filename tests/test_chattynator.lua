-- Chattynator hides Blizzard's chat frames and draws its own window. Other addons
-- change lines through Chattynator.API.AddModifier(function(data) data.text = ... end);
-- modifiers run in a list on a fresh copy of the stored line every time it's drawn, a
-- modifier that errors is removed, and protected (secret) text is never passed in.
local H = dofile("tests/harness.lua")

-- Chattynator-style built-in modifiers (own implementations of the same behaviour).
-- Level: only recognises a plain label "[<colour>Name<|r>]" and adds " (60)".
local function Level(data)
    data.text = data.text:gsub("(|Hplayer:[^|]+|h)(%[?)(|?)([^|]-)(|?r?)(%]?)(|h)", "%1%2%3%4 (60)%5|r%6%7")
end
-- "letter" channel style: drops the [ ] around player names.
local function StripBrackets(data)
    data.text = data.text:gsub("(|Hplayer[^:]*:[^|]-|h)%[([^%[%]]-)%](|h)", "%1%2%3", 1)
end

-- opts.position: where WhoDis's modifier ends up: "first", "middle" or "last"
-- opts.whodisFirst: WhoDis loads before Chattynator (registers on Chattynator's ADDON_LOADED)
local function StartChattynator(opts)
    local live, removed = {}, 0
    local function install()
        _G.Chattynator = { API = {} }
        function _G.Chattynator.API.AddModifier(func)
            local wrapper
            wrapper = function(data)
                if not pcall(func, data) then
                    for i, f in ipairs(live) do if f == wrapper then table.remove(live, i) end end
                    removed = removed + 1
                end
            end
            if opts.position == "first" then table.insert(live, 1, wrapper) else live[#live + 1] = wrapper end
            opts.whodisWrapper = wrapper
        end
    end
    local W = H.Start({
        beforeLoad = function() if not opts.whodisFirst then install() end end,
        afterAddonLoaded = function(W)
            if opts.whodisFirst then install(); W.event("ADDON_LOADED", "Chattynator") end
            if opts.position == "last" then
                table.insert(live, 1, StripBrackets); table.insert(live, 1, Level)
            elseif opts.position == "first" then
                live[#live + 1] = Level; live[#live + 1] = StripBrackets
            else
                table.insert(live, 1, Level); live[#live + 1] = StripBrackets
            end
        end,
    })
    -- Chattynator unregisters chat events from Blizzard's frames: lines only reach its modifiers.
    function W.chattyLine(text)
        local data = { text = text, typeInfo = { player = { name = "x", level = 60 } } }
        if not (type(text) == "table" and text.secret) then
            for _, f in ipairs(live) do f(data) end
        end
        return data.text
    end
    function W.removedCount() return removed end
    W.whodisModifier = opts.whodisWrapper
    return W
end

for _, cfg in ipairs({
    { position = "last" }, { position = "first" }, { position = "middle" },
    { position = "last", whodisFirst = true },
}) do
    H.section(("Chattynator, WhoDis modifier %s%s"):format(cfg.position,
        cfg.whodisFirst and ", WhoDis loaded before Chattynator" or ""))
    local W = StartChattynator(cfg)
    local line = W.chattyLine(H.GuildLine("Lock Guy-Mankrik", "Lock Guy", "hi", 9))
    H.check("Chattynator's level is kept", H.has(line, "(60)"), line)
    H.check("WhoDis's note is added once", H.count(line, "(warlock main)") == 1, line)
    H.check("bracket stripping still works", not H.has(line, "|h["), line)
    H.check("no marker codes in Chattynator lines (they'd break its patterns)", not H.has(line, H.MARK), line)
    local again = W.chattyLine(H.GuildLine("Lock Guy-Mankrik", "Lock Guy", "hi", 9))
    H.check("redrawing from the stored line gives the same result", again == line, again)
    H.check("WhoDis put no hooks on Blizzard's chat frames", W.hookCount == 0, W.hookCount)
    H.check("WhoDis's modifier never errored (Chattynator would remove it)", W.removedCount() == 0)
    W.slash("status")
    H.check("/whodis status reports Chattynator mode", H.has(W.output(), "Chattynator detected"), W.output())
end

H.section("Chattynator: odd input never makes the modifier error")
do
    local W = StartChattynator({ position = "last" })
    H.check("WhoDis registered exactly one modifier", W.whodisModifier ~= nil)
    for _, data in ipairs({ { text = 42 }, {}, { text = H.Secret("protected") },
                            { text = "no links here" }, { text = "|Hplayer:|h[]|h broken link" } }) do
        if W.whodisModifier then W.whodisModifier(data) end
    end
    H.check("modifier still registered after odd input", W.removedCount() == 0)
end

H.finish()

# WhoDis

A World of Warcraft: Forever addon that shows a guildmate's **public guild note** next to their name in chat.

```
[Bean Sommelier]: hello        ->   [Bean Sommelier(snerf)]: hello
```

- Keeps Blizzard's class colour on the name; clicking, right-clicking and whispering a name work as normal.
- Works with the default chat and with the EllesmereUI Chat module.
- Leaves protected chat (encounters, Mythic+, PvP, instances) untouched.

## Commands

| Command | What it does |
| --- | --- |
| `/whodis on` / `/whodis off` | Turn notes in chat on or off (on by default). |
| `/whodis refresh` | Re-read the guild roster now. |
| `/whodis color RRGGBB` / `/whodis color off` | Colour the note, or let it follow the channel colour. |
| `/whodis test [name]` | Print a sample line to check it works. |
| `/whodis status` / `/whodis debug` | Troubleshooting info. |

`/wd` works as a short alias.

## Releasing

Push a tag such as `v1.0.0`; the GitHub Action packages the addon with the
[BigWigs packager](https://github.com/BigWigsMods/packager) and uploads it to
CurseForge and GitHub Releases.

## License

MIT, see [LICENSE](LICENSE).

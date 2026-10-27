MIR — Modded Item Randomizer, v1.2.1 — four descriptions that were not true.

**Text only.** Nothing MIR does has changed, and the Lua is byte-identical to v1.2.0 apart from the version in the startup banner. What changed is what MIR says about itself.

An adversarial review of the v1.2.0 documentation against the shipped code turned up four claims a player could disprove on screen, three of them in MIR's own help text inside MCM — which is the first thing anyone reads, and the reason this is a release of its own rather than a note for next time.

**"Excluded Mods skips two kinds of modded item" — it skips three.** NPC gear, the mods on MIR's own list, and the **three containers** on that same list: the game's own rich wardrobe and wicker baskets, and the Ultimate Cut Content chest. The container rules hold back items whose own mod is *not* on the mod list — that is the whole reason they exist, and three of the fourteen rows in the list have always been containers.

**"the utility mods and the NPC or companion gear … have no toggle."** The NPC-gear view has none. The utility view follows **Exclude known utility mods** on the Pool tab, and says so in its own description one screen away. The reason given for both — that the gear belongs to its intended character — never applied to photo-mode tools and framework libraries.

**"all three per-item lists are normally managed from the MIR Browser tab" — only the first is.** The Browser shows you which items are held back, but it has no control to let one in: **Items allowed in anyway** is set in MCM or with `!mir_forceinclude`. And **Extra items MIR may place, in chests only** takes a stat name typed into MCM or set with `!mir_extra`, because the Browser cannot show an item that is not in the pool at all.

**"an item MIR is holding back … with a button to allow it in anyway" — there is no such button, and never was.** The item rows are a tick box and two columns of text. This one was wrong in the v1.1.2 README too.

Two smaller corrections in the same pass: unticking the box above the exclusion list frees MIR's own suggestions but **not** a mod you excluded yourself, which applies either way; and two of the three container rules are the game's own furniture, so they are no longer described as something "the mod really does place".

**Upgrading from v1.2.0?** Nothing to do, and nothing to undo. Your settings, exclusion lists and no-duplicate ledger all carry over — MIR keys every one of them to its module UUID, not its version. If you would rather stay on v1.2.0, nothing it *does* is wrong, only some of what it says.

**Requires** BG3 Script Extender (v29+) and Mod Configuration Menu (Nexus 9162), loaded above MIR. MIR disables itself if MCM is absent.

**Download:** `MIR-1.2.1.zip` — `MIR.pak` plus README / INSTALL (md, docx, pdf), CHANGELOG, LICENSE, third-party notices and the Nexus description.

| File | SHA256 |
|---|---|
| MIR.pak (142,755 bytes) | `DD0E11A9BBF4A4EBDCF00C516E47C2C8B2724B8437E0AC49722807DE01CA7826` |
| MIR-1.2.1.zip (302,790 bytes) | `B3BFDFD66E5C7845B7C8B963DEF27D88A62A2A4A385953A79458718174490904` |

The [tutorial video](https://youtu.be/-Be4ZjbuKY8) was recorded against v1.1.2 and carried the same four claims. Its narration has been rewritten and is being re-recorded; until that re-cut is published, the video on YouTube shows the older build. Source for this build is the `main` branch at this tag. See `docs/CHANGELOG.md` for the full history.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

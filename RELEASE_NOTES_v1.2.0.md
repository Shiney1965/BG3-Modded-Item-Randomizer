MIR — Modded Item Randomizer, v1.2.0 — a mod's own bag is delivery, not placement.

**MIR stops assuming that a container a mod ships is placed in the game world.** Until now, anything inside such a container was held out of MIR's pool so you could never be handed a duplicate. That was a guess, and usually the wrong one: MIR can see that a mod lists an item in a container, but **not** whether that container is placed anywhere, because placement lives in level data no mod can read — and most mods simply hand you a backpack. On the author's 1,610-module load order the old rule held back **5,575 items**; the new one holds back **659** and returns **4,927** to the pool.

**What still keeps an item out:** gear a mod puts on a specific NPC, and the mods and containers on MIR's own shipped list — eleven mods that really do place their container in the world or ship hundreds of near-identical variants, plus the game's own rich wardrobe and wicker baskets, and the Ultimate Cut Content add-on's chest.

**The list is yours, and it is one list.** The Exclusion lists tab is now **Exclusions and overrides**, and it opens with **Mods MIR does not use**: every mod MIR skips, by name, ticked. Untick a row — or delete it with the X — and MIR starts using that mod from the next rebuild, which happens by itself while you are in a game, or at the next load if you change it from the main menu. Unticking the box above the list lets MIR use all of them at once, and re-ticking restores every row exactly as it was. Mods you exclude yourself in the MIR Browser tab appear in the same list. Everything else on that tab — three per-item lists and two read-only views — now sits behind a **Show the advanced lists** checkbox, off by default.

**Renamed: "Exclude items their mod already places in the world" is now "Excluded Mods".** The old name claimed something MIR cannot detect. The setting's id is unchanged, so your configuration carries over untouched.

**Reporting.** `!mir_tables` now prints the reason beside every held-back item (`npc`, `mod-list`, `container-list`), lists the items a mod places that MIR spawns anyway, and says whether each row of the shipped list matched anything. `!mir_placed lists` prints that list with each row's current state. `!mir_placed_mods` gains a **fenced** column, because "a mod places this too" and "MIR holds it back" are no longer the same thing. In the MIR Browser, an item MIR will spawn although its mod also places it now reads *ALSO PLACED IN THE WORLD — you may find two*, which is the honest warning.

**Upgrading from v1.1.2? Expect more loot, and expect the occasional duplicate.** An item freed by this change can reach you twice — once where its mod puts it, once from MIR. On an existing save the freed items become spawnable immediately, and MIR's no-duplicate ledger cannot know you already own the mod's copy from a camp chest. Nothing is removed from your save, and every part of this is reversible from the new list.

**Requires** BG3 Script Extender (v29+) and Mod Configuration Menu (Nexus 9162), loaded above MIR. MIR disables itself if MCM is absent.

**Download:** `MIR-1.2.0.zip` — `MIR.pak` plus README / INSTALL (md, docx, pdf), CHANGELOG, LICENSE, third-party notices and the Nexus description.

| File | SHA256 |
|---|---|
| MIR.pak (142,498 bytes) | `6ED80F45FD6A4A88DE5012CCFCA134BBFE6CDB8D78B8E90355CE4F8C01C87181` |
| MIR-1.2.0.zip (297,283 bytes) | `9B86892A9AB7697BCD5BA5B5C23BCA3A170C133F8FD06BC75EBCA4A92C8C4E7F` |

The [tutorial video](https://youtu.be/-Be4ZjbuKY8) was recorded against v1.1.2, so it shows the old setting name and the old behaviour; a re-cut is coming. Source for this build is the `main` branch at this tag. See `docs/CHANGELOG.md` for the full history.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

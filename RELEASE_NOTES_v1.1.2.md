MIR — Modded Item Randomizer, v1.1.2 — scroll detection, and an allow-list for odd items.

**Fixed: things that are not scrolls were being placed as scrolls.** A few mods set the game's `ItemUseType` field to "Scroll" on items that are not scrolls at all, and MIR took that field at its word, so those items were catalogued as scrolls and turned up in bookshelves and desks. MIR now requires corroboration before filing something as a scroll — the magical inventory tab, which every vanilla scroll inherits, or "Scroll" in the item's own stat name or object category. Measured against the vanilla game data, the same 111 scroll entries are recognised as before: none lost, none gained. Whatever the stricter rule turns away is named in `MIR_log.txt` each time the pool is built, so a genuine modded scroll that follows none of the conventions can still be found and added back.

**Added: Extra items (chests only).** MIR only catalogues equipment and the consumables it recognises, so anything else a mod adds — kits, crafting pieces, oddities — is skipped. The new editable list on the **Exclusion lists** tab lets items back in one at a time, by stat name as `MIR_log.txt` prints it or by root template UUID. Listed items are admitted whatever their type, are drawn **in chests only**, carry their own share slider in the MIR Browser, are tracked by the no-duplicate ledger like equipment, and ignore the rarity window. `!mir_extra`, `add`, `remove` and `clear` do the same from the console. **Empty by default: with nothing listed, MIR behaves exactly as v1.1.1 did.**

**Upgrading from v1.1.1?** Nothing to do, and nothing changes for an existing save unless you use the new list. Items that were wrongly catalogued as scrolls simply leave the pool at the next catalogue build; anything already spawned is untouched.

**Requires** BG3 Script Extender (v29+) and Mod Configuration Menu (Nexus 9162), loaded above MIR. MIR disables itself if MCM is absent.

**Download:** `MIR-1.1.2.zip` — `MIR.pak` plus README / INSTALL (md, docx, pdf), CHANGELOG, LICENSE, third-party notices and the Nexus description.

| File | SHA256 |
|---|---|
| MIR.pak (119,200 bytes) | `7F22256B53FDF75769E8CCF93BBEF69F921EE846686F55CEED1A584F5F010A57` |
| MIR-1.1.2.zip (269,327 bytes) | `F4B20B84262998A80CFA5CCCB49BFBE4286A0A557EB9F771D93E32971B5DFF04` |

Source for this build is the `main` branch at this tag. See `docs/CHANGELOG.md` for the full history.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

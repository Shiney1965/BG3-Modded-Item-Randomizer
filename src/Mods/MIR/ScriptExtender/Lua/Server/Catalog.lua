-- MIR catalog engine (Phase 2): runtime enumeration of modded items.
-- Built once per session at SessionLoaded (~116 ms measured on Alan's 1,478-mod order).
-- Classification rules are the ones VERIFIED by the 2026-08-14 catalog probe:
--   * defining mod = stat.OriginalModId (fallback ModId) — NOT ModId, which names the last overrider
--   * shields are Armor entries with Slot == "Melee Offhand Weapon"
--   * potions/elixirs = InventoryTab "Consumable" + Using-ancestry reaching "_Potion",
--     or ObjectCategory beginning "Potion"
MIR = MIR or {}
MIR.Catalog = { built = false }

local SLOT_TO_CATEGORY = {
    Helmet = "helmet", Gloves = "gloves", Breast = "torso", Boots = "boots",
    Cloak = "cloak", Ring = "ring", Amulet = "amulet",
    VanityBody = "vanityClothing", VanityBoots = "vanityBoots", Underwear = "underwear",
    ["Melee Offhand Weapon"] = "shield",
    -- MusicalInstrument / Horns: deliberately unmapped -> excluded
}

-- Per-mod info, memoized for the session (the mod registry cannot change
-- mid-session, so the cache legitimately survives !mir_rebuild / !mir_util).
-- Failed lookups are cached too: GetMod is deterministic per UUID per session.
local modInfoCache = {}
local EMPTY_INFO = { base = false, name = nil }
local function modInfo(uuid)
    if uuid == nil or uuid == "" then return EMPTY_INFO end
    local cached = modInfoCache[uuid]
    if cached then return cached end
    local info = { base = false, name = nil }
    pcall(function()
        local m = Ext.Mod.GetMod(uuid)
        if m and m.Info then
            local n = tostring(m.Info.Name or "")
            info.name = (n:gsub("^%s+", ""):gsub("%s+$", "")) -- trimmed for byName matching
            if MIR.BaseModuleNames[m.Info.Name] then info.base = true end
        end
    end)
    modInfoCache[uuid] = info
    return info
end

local utilNameOnlyLogged = {} -- one diagnostic line per mod name per session

-- Walk the Using chain (bounded) to detect potion-family Objects.
local function isPotionFamily(stat, statName)
    local oc = ""
    pcall(function() oc = tostring(stat.ObjectCategory or "") end)
    if oc:sub(1, 6) == "Potion" then return true end
    local tab = ""
    pcall(function() tab = tostring(stat.InventoryTab or "") end)
    if tab ~= "Consumable" then return false end
    local cur, depth = stat, 0
    while cur and depth < 8 do
        local using = ""
        pcall(function() using = tostring(cur.Using or "") end)
        if using == "" then return false end
        if using == "_Potion" or using == "_Potion_Of_Resistance" then return true end
        local nxt = nil
        pcall(function() nxt = Ext.Stats.Get(using) end)
        cur, depth = nxt, depth + 1
    end
    return false
end

-- Prefix test with the length COMPUTED from the prefix. A literal length is how the v0.9
-- `sub(1, 8)` against a seven-character prefix made a clamp unreachable; never again.
local function hasPrefix(s, prefix) return s:sub(1, #prefix) == prefix end

-- Walk the Using chain (bounded, same shape as isPotionFamily) to detect the wand family.
local function isWandFamily(stat, statName)
    if statName == "OBJ_Wand" or statName == "_Wand" then return true end
    local cur, depth = stat, 0
    while cur and depth < 8 do
        local using = ""
        pcall(function() using = tostring(cur.Using or "") end)
        if using == "" then return false end
        if using == "_Wand" or using == "OBJ_Wand" then return true end
        local nxt = nil
        pcall(function() nxt = Ext.Stats.Get(using) end)
        cur, depth = nxt, depth + 1
    end
    return false
end

-- v1.1.2 (SF-13): stat names the tightened scroll rule turned away - ItemUseType "Scroll"
-- with nothing corroborating it. Capped and reset per build, logged at the end of
-- BuildCatalog, so a genuine modded scroll that follows none of the three conventions is
-- still findable instead of silently vanishing from the pool.
-- v1.1.2 (diff review S-6): the allow-list report is logged only when it CHANGES.
local lastExtraReportSig = nil
local scrollRejects, scrollRejectCount = {}, 0
local SCROLL_REJECT_CAP = 12
local function resetScrollRejects() scrollRejects, scrollRejectCount = {}, 0 end
local function noteScrollReject(statName, tab, oc)
    scrollRejectCount = scrollRejectCount + 1
    if #scrollRejects < SCROLL_REJECT_CAP then
        scrollRejects[#scrollRejects + 1] = ("%s (tab=%s cat=%s)")
            :format(statName, tab ~= "" and tab or "-", oc ~= "" and oc or "-")
    end
end

-- Consumable classifier (Phase 3 §2.3). NORMATIVE match order: potion -> arrow
-- -> alchemyIngredient -> scroll; first match wins. Returns a category name or nil.
-- ALCH_Solution_* deliberately NOT an ingredient rule (they are potion-family
-- elixirs or coatings, review S5).
-- v1.0 scrolls, verified against the vanilla extract (2026-09-01): every vanilla scroll stat
-- is OBJ_Scroll_*, inherits `_MagicScroll` which carries ItemUseType "Scroll", and has an
-- ObjectCategory beginning "MagicScroll" (MagicScroll, MagicScroll_2 .. _9, MagicScroll_Necro_3
-- ...). Their ROOT TEMPLATES are LOOT_SCROLL_* - NOT BOOK_GEN_Scroll_*, which is decorative
-- parchment. The test is stat-only, reading no template: name prefix OR a MagicScroll
-- ObjectCategory OR a QUALIFIED ItemUseType - and the v1.1.2 block at the point of use below
-- is the authority on that qualification, not this paragraph (diff review S-4). The
-- extra-items allow-list further down the Object branch does read RootTemplate early, but only
-- after this function has returned nil. Seven vanilla scrolls sit in the cut-content
-- category "MagicScroll_ToBeDeleted" (OBJ_Scroll_Aid, _AnimalFriendship ...) and are skipped.
local function consumableCategory(stat, statName)
    if isPotionFamily(stat, statName) then return "potion" end
    local oc, tab = "", ""
    pcall(function() oc = tostring(stat.ObjectCategory or "") end)
    pcall(function() tab = tostring(stat.InventoryTab or "") end)
    if hasPrefix(oc, "Arrow") then return "arrow" end
    if tab == "Consumable" and (hasPrefix(statName, "OBJ_Arrow") or hasPrefix(statName, "ARR_")) then
        return "arrow"
    end
    if oc == "Ingredient" or hasPrefix(statName, "ALCH_Ingredient_") then
        return "alchemyIngredient"
    end
    local byName = hasPrefix(statName, "OBJ_Scroll_") or (oc:find("MagicScroll", 1, true) ~= nil)
    local useType = ""
    pcall(function() useType = tostring(stat.ItemUseType or "") end)
    -- Diff review SF-1: vanilla `_Wand` (and OBJ_Wand / TOOL_Wand_Fireballs under it) ALSO
    -- carries ItemUseType "Scroll". Vanilla wands have no RootTemplate and die later, but a
    -- modded wand inheriting _Wand with a template would have been filed as a scroll -
    -- repeatable, ledger-exempt, and landing in bookshelves. The use-type test therefore
    -- excludes anything whose Using chain reaches the wand family.
    -- v1.1.2: ItemUseType alone is NOT evidence of a scroll. Two mods in Alan's load order set
    -- it on things that are not scrolls - CRA_ShellKid_Cup (HT_Early Access Scenes Restored,
    -- 868bf4c5-e0ee-44de-875e-315462e6bf42) and Goon_OBJ_Injury_Kit_B (Grit and Glory,
    -- 5442c1bf-c118-48bc-87f1-c90bcc024b1c) - and v1.1.1 filed both as scrolls, so they
    -- spawned in bookshelves and desks. The use-type test is now a QUALIFIED arm: it must be
    -- corroborated by the magical inventory tab (every vanilla scroll resolves to it through
    -- _MagicScroll) or by "Scroll" appearing in the stat name or the object category.
    -- Measured against the vanilla extract 2026-10-15: 111 scroll stats before AND after the
    -- change - none lost, none gained - and both reported items rejected. The Using chain is
    -- deliberately NOT a qualifier: the cup's Using reads back EMPTY at runtime (console probe,
    -- 2026-10-10), so a chain walk fails exactly where mod overrides make it matter.
    -- `not byName` first so an already-matched scroll never pays for the chain walk.
    local scrollish = (not byName) and useType == "Scroll" and not isWandFamily(stat, statName)
    local byUseType = scrollish and (tab == "Magical"
        or statName:find("Scroll", 1, true) ~= nil or oc:find("Scroll", 1, true) ~= nil)
    if byName or byUseType then
        if oc:find("ToBeDeleted", 1, true) then return nil end
        return "scroll"
    end
    if scrollish then noteScrollReject(statName, tab, oc) end
    return nil
end

-- v1.1: a scope set holds ONLY true keys (plan review SF-1). nil when nobody asked, so an
-- empty table can never mean "drawable nowhere".
local function scopeSet(want)
    local s, any = {}, false
    for class, on in pairs(want) do
        if on then s[class] = true any = true end
    end
    return any and s or nil
end

-- "barrels + vases" - readable text for a scope set, in loot-source order. nil for nil.
function MIR.ScopeText(scope)
    if not scope then return nil end
    local parts = {}
    for _, k in ipairs(MIR.SourceKeys) do
        if scope[k] then parts[#parts + 1] = MIR.SourceNames[k] or k end
    end
    return table.concat(parts, " + ")
end

-- "barrels=12 vases=12 bookshelves=40" from catalogue stats (log lines)
function MIR.ScopedSummary(stats)
    local parts = {}
    for _, k in ipairs(MIR.SourceKeys) do
        local n = stats and stats.scoped and stats.scoped[k]
        if n and n > 0 then parts[#parts + 1] = (MIR.SourceNames[k] or k) .. "=" .. n end
    end
    return #parts > 0 and table.concat(parts, " ") or "none"
end

function MIR.BuildCatalog()
    -- Treasure-table index: one-shot per session, a no-op on every later rebuild
    -- (see TreasureIndex.lua). Skipped entirely while the toggle is off, so users
    -- who do not want the feature never pay for the scan. Deliberately OUTSIDE the
    -- builtMs window — it logs its own timing line and would otherwise make the
    -- first "Catalog built in N ms" line unreadable.
    if MIR.Config.excludeTreasureTableItems and MIR.EnsureTreasureIndex then
        pcall(function() MIR.EnsureTreasureIndex("catalog") end)
    end
    local t0 = Ext.Utils.MonotonicTime()
    local cfg = MIR.Config
    local pool = {}          -- pool[category][rarityName] = array of entries
    local byTemplate = {}    -- [rootTemplateUuid] = entry (dedupe + ledger removal)
    local userExcluded = {}  -- [rootTemplateUuid] = fully-classified entry the USER
                             -- excluded (kept for the browser's un-exclude path, B2)
    local tableExcluded = {} -- [rootTemplateUuid] = fully-classified entry fenced because
                             -- the item already has a TREASURE-TABLE distribution (§5.1 #13).
                             -- Kept separate from userExcluded so the two exclusion KINDS stay
                             -- distinguishable, and retained (not dropped) so the browser can
                             -- still show the item and say why it is out.
    resetScrollRejects()
    local stats = { seen = 0, eligible = 0, skippedBase = 0, skippedStory = 0,
                    skippedNoTemplate = 0, skippedNoName = 0, skippedDupe = 0,
                    skippedUnmappedSlot = 0, skippedExcluded = 0, skippedConsumable = 0,
                    skippedTreasureTable = 0, forceIncluded = 0,
                    -- v1.0: Objects that match no consumable/scroll rule. Previously they
                    -- vanished without bumping anything, so "my modded scroll is missing"
                    -- was indistinguishable from "it was never seen".
                    skippedUncategorised = 0,
                    -- v1.1.2: how many allow-list entries actually made it into the pool
                    extraAdmitted = 0,
                    -- v1.0.1: how much of the eligible pool is reserved for one container class.
                    -- v1.1: per class ([class] = n); an entry scoped to two classes counts in each.
                    scoped = {},
                    -- these two count raw STAT entries fenced (incl. ones that would have
                    -- failed later filters anyway) — NOT eligible-item impact
                    skippedUtilityStats = 0, skippedNpcGearStats = 0 }

    -- v1.1.2 allow-list bookkeeping (diff review S-5 and S-1). extraMatched records the keys
    -- that actually reached the pool, so the report below is one pass over the list instead of
    -- a scan of the whole pool per entry; extraNote records WHY a listed key was not admitted
    -- in the two cases worth naming - it is an equipment stat, or MIR already categorises it.
    local extraMatched, extraNote = {}, {}

    local function addEntry(statName, category, rarity, tplId, modKey, dispName, consumable, tplName, baseMod, scope)
        local entry = { stat = statName, template = tplId, category = category,
                        rarity = rarity, mod = modKey, name = dispName, tplName = tplName,
                        consumable = consumable or false, spawned = false,
                        -- review S7: the placement fence and every 'placed by mod' label are
                        -- MODDED-ONLY, but consumers outside addEntry had no way to tell a
                        -- base-game row from a modded one and mislabelled vanilla items as
                        -- "placed by mod" whenever includeBaseGame was on. Store it.
                        base = baseMod or false,
                        -- v1.1 (was clutterOnly / bookshelfOnly, v0.9-v1.0.1): the SET of loot
                        -- sources that admitted this entry when the Pool tab did not - e.g.
                        -- { clutter = true, vase = true } - or nil = pool-wide. Only true keys
                        -- are ever stored (plan review SF-1). LOAD-BEARING: Main.lua
                        -- entryAllowedFor makes a scoped entry drawable in those sources and
                        -- nowhere else, which is what lets barrels, vases and bookshelves admit
                        -- VANILLA consumables and scrolls without leaking into chests.
                        -- Reported by !mir_pool and the MIR Browser item rows.
                        scope = scope }
        -- User exclusion check sits HERE, after full classification (B2): the
        -- entry is retained with all metadata so the browser can un-exclude it.
        -- skippedExcluded therefore counts otherwise-ELIGIBLE entries only.
        -- It is checked FIRST because an explicit user choice outranks the
        -- automatic treasure-table fence (and the browser checkbox must reflect it).
        if MIR.Config.excludedModUuids[modKey] or MIR.Config.excludedTemplates[tplId] then
            entry.excluded = true
            userExcluded[tplId] = entry
            stats.skippedExcluded = stats.skippedExcluded + 1
            return
        end
        -- Treasure-table fence (§5.1 #13, toggle-gated). Also late/post-classification
        -- so the browser gets a fully populated row to display.
        -- the nil check is load-order insurance: a missing TreasureIndex.lua must
        -- degrade to "no fence", never take the whole catalog build down with it.
        -- SCOPE (review B1 + recommendation): MODDED, NON-CONSUMABLE items only.
        --   * base-game items are excluded from the fence. DO NOT REMOVE `not baseMod`
        --     WITHOUT READING THIS. It was removed on 2026-08-24 to try to stop MIR
        --     respawning the Warped Headband of Intellect, and REVERTED the same day
        --     when an adversarial review extracted vanilla data and measured what the
        --     change actually does:
        --       - It does NOT fix the Headband. Vanilla assigns NPC and container loot
        --         on LEVEL INSTANCES, not root templates. The Headband's only vanilla
        --         treasure reference is the table FOR_SchoolOgre_Smart_Corpse, which is
        --         referenced by ZERO root templates (the ogres are level instances in
        --         WLD_Main_A). Ext.Template.GetAllRootTemplates() cannot see it, so the
        --         item is never indexed and never fenced. Only ~6.5% of vanilla treasure
        --         tables are reachable from root templates at all.
        --       - It fences the WRONG items. Measured on vanilla: 66/834 Armor and
        --         20/478 Weapon stats, and they are overwhelmingly MUNDANE generic loot,
        --         because vanilla hangs generic tables off a single archetype template.
        --         The whole martial weapon set (Longsword, Greatsword, Dagger, ...) goes
        --         via Monster_OchreJelly -> T_ST_MartialMeleeWeapons on the single
        --         template Ooze_Jelly_Ochre; plain rings and necklaces via a BIRD'S NEST
        --         (GEN_Nest_Small on CONT_GEN_Nest_Small_A); boots and hats via wardrobe
        --         tables. Exactly ONE authored unique was caught. GENERIC_REF_LIMIT = 5
        --         cannot help: these reference counts are 1, not >5.
        --     If this is ever revisited, the avenue NOT yet tried is
        --     Ext.Template.GetAllLocalTemplates() (server-side; it exists and is where
        --     level-instance Treasures nodes live) — but it is level-scoped, so an index
        --     built from it is partial and would need accumulating as the player travels.
        --     The only mechanism that helps a MID-PLAYTHROUGH install is an
        --     "already in the party's possession" check at spawn time.
        --   * consumables are exempt because MIR deliberately hands them out
        --     repeatedly (the no-duplicate ledger is equipment-only), so "don't give
        --     you a second copy" — the fence's whole rationale — does not apply.
        -- v1.1.2 (plan review SF-4): allow-list entries are exempt from the placement fence.
        -- The user named the item explicitly; fencing it would make the list silently do nothing.
        if MIR.Config.excludeTreasureTableItems and not baseMod and not consumable
           and category ~= "extra"
           and MIR.HasTreasureDistribution
           and MIR.HasTreasureDistribution(statName, tplName) then
            entry.placed = true
            -- Cache the placement source HERE (review S1). HasTreasureDistribution has just
            -- returned true, so the lookup is warm; recomputing it per browser row per page
            -- turn would be pure waste.
            if MIR.TreasureSourceOf then
                local okS, tbl, via, kind = pcall(MIR.TreasureSourceOf, statName, tplName)
                if okS then
                    entry.placedTable = tbl
                    entry.placedVia = via
                    entry.placedKind = kind
                end
            end
            -- FORCE-INCLUDE (v0.7). Tested INSIDE the branch, deliberately: adding
            -- `and not forceIncluded[tplId]` to the condition above would skip the whole
            -- branch, so entry.placed would never be set and every downstream consumer -
            -- the per-mod placed count and the duplicate warning - would lose the one fact
            -- they depend on (review B1/S2 of the v0.7 plan review). The item stays MARKED
            -- as placed; it just is not fenced.
            if MIR.Config.forceIncludedTemplates and MIR.Config.forceIncludedTemplates[tplId] then
                entry.forced = true
                stats.forceIncluded = stats.forceIncluded + 1
                -- fall through to the pool
            else
                tableExcluded[tplId] = entry
                stats.skippedTreasureTable = stats.skippedTreasureTable + 1
                return
            end
        end

        pool[category] = pool[category] or {}
        pool[category][rarity] = pool[category][rarity] or {}
        table.insert(pool[category][rarity], entry)
        byTemplate[tplId] = entry
        stats.eligible = stats.eligible + 1
        if entry.scope then
            for c in pairs(entry.scope) do stats.scoped[c] = (stats.scoped[c] or 0) + 1 end
        end
    end

    local function considerEntry(statName, stype)
        stats.seen = stats.seen + 1
        if statName:sub(1, 1) == "_" then return end
        local ok, stat = pcall(Ext.Stats.Get, statName)
        if not ok or not stat then return end

        local mid, omid = "", ""
        pcall(function() mid = tostring(stat.ModId or "") end)
        pcall(function() omid = tostring(stat.OriginalModId or "") end)
        local modKey = (omid ~= "" and omid) or mid

        local info = modInfo(modKey)
        local baseMod = info.base
        -- (user mod/template excludes are checked LATE, inside addEntry — B2)

        -- NPC/character-gear fence — UNCONDITIONAL, no toggle (Alan 2026-08-20):
        -- gear meant for a specific NPC/companion never enters the pool.
        if MIR.NpcGearMods.byUuid[modKey] then
            stats.skippedNpcGearStats = stats.skippedNpcGearStats + 1
            return
        end

        -- Curated utility-mod fence (default ON; applies to Armor+Weapon+Object alike)
        if cfg.excludeUtilityMods then
            local byUuid = MIR.UtilityMods.byUuid[modKey]
            if byUuid or MIR.UtilityMods.byName[info.name] then
                if not byUuid and info.name and not utilNameOnlyLogged[info.name] then
                    utilNameOnlyLogged[info.name] = true
                    if MIR.Log then MIR.Log("utility-excluded via NAME match (uuid not listed): "
                                            .. info.name .. " [" .. modKey .. "]") end
                end
                stats.skippedUtilityStats = stats.skippedUtilityStats + 1
                return
            end
        end

        -- category (base-game gating is PER BRANCH so consumable base/modded checkboxes
        -- stay independent of includeBaseGame, per spec §5.1 #3)
        local category
        local consumable, scope, extraHit = false, nil, nil
        -- v1.1.2 (diff review S-1, plan review SF-7): the allow-list admits ONLY Objects that
        -- no category rule claimed. A listed name that turns out to be an equipment stat is
        -- never admitted, so record the reason rather than reporting "matched nothing".
        if stype ~= "Object" and (cfg.extraChestItems or {})[statName] then
            extraNote[statName] = "it is an equipment stat (" .. tostring(stype)
                .. "), which the allow-list cannot admit"
        end
        if stype == "Weapon" then
            if baseMod and not cfg.includeBaseGame then stats.skippedBase = stats.skippedBase + 1 return end
            category = "weapon"
        elseif stype == "Armor" then
            local slot = ""
            pcall(function() slot = tostring(stat.Slot or "") end)
            category = SLOT_TO_CATEGORY[slot]
            if not category then stats.skippedUnmappedSlot = stats.skippedUnmappedSlot + 1 return end
            if baseMod and not cfg.includeBaseGame then stats.skippedBase = stats.skippedBase + 1 return end
        else -- Object
            -- NOTE (v1.0 review SF-6): there is deliberately NO includeBaseGame test in this
            -- branch. Base-game gating is per branch (spec §5.1 #3), and it is what lets
            -- bookshelves admit VANILLA scrolls locally and the base-consumables toggle work
            -- independently of "Include base-game items". Adding one "for symmetry" kills
            -- both features silently.
            category = consumableCategory(stat, statName)
            if not category then
                -- v1.1.2: the extra-items allow-list. Checked ONLY here, where no category rule
                -- matched, so listing a potion can never demote potions to chest-only (plan
                -- review SF-7). RootTemplate is read EARLY because the shared read at the end of
                -- considerEntry happens after this decision (plan review BL-4).
                local rtEarly = ""
                pcall(function() rtEarly = tostring(stat.RootTemplate or "") end)
                local allow = cfg.extraChestItems or {}
                if allow[statName] or (rtEarly ~= "" and allow[rtEarly]) then
                    category = "extra"
                    -- BOTH listed forms are recorded (verification F-3): a user who lists
                    -- the stat name AND its root-template UUID would otherwise have the
                    -- second one reported as not in the pool.
                    extraHit = {}
                    if allow[statName] then extraHit[#extraHit + 1] = statName end
                    if rtEarly ~= "" and allow[rtEarly] then extraHit[#extraHit + 1] = rtEarly end
                    -- hard-coded, NOT scopeSet: an empty set from scopeSet means pool-wide
                    -- (plan review SF-2). Chests and nowhere else.
                    scope = { treasure = true }
                else
                    -- counted for MODDED objects only (diff review M-2): every vanilla book, key,
                    -- note and prop would otherwise swamp the number and it would answer nothing
                    if not baseMod then stats.skippedUncategorised = stats.skippedUncategorised + 1 end
                    return
                end
            elseif (cfg.extraChestItems or {})[statName] then
                -- listed, but a category rule claimed it first. Admitting it as "extra" would
                -- demote a whole category to chests (plan review SF-7), so it is left alone -
                -- and named, because from the outside it looks like the list did nothing.
                extraNote[statName] = "MIR already catalogues it as " .. tostring(category)
            end
            if category == "extra" then
                -- the list IS the admission: no Pool toggle, no per-source box. Ledger-tracked
                -- (consumable stays false, plan review SF-5), so one copy per save like
                -- equipment. NOTHING is counted here (verification F-1): the gates below -
                -- no template, story/key, no display name, duplicate template - and addEntry's
                -- own exclusion check can still drop it, and counting at this point printed
                -- "1 of 1 admitted to the pool" directly above "1 of 1 are NOT in the pool".
                -- The counter is bumped where the entry actually lands, below.
            elseif category == "scroll" then
                -- v1.0: scrolls have their OWN admission arms and ignore the consumable
                -- toggles entirely (review BL-3: without these two arms the new setting
                -- admitted nothing). ONE global switch, no base/modded split, so the
                -- per-category draw gate (Main.lua categoryEnabled, keyed on
                -- filter.allowScrolls) is exactly sufficient - see Config.includeScrolls.
                -- v1.1: barrels and vases on "everything" admit scrolls for themselves too
                -- (Alan's Q5: "no gate on UI toggle").
                local wantScroll = cfg.includeScrolls
                local wantShelf = cfg.includeBookshelves and cfg.bookshelfScrolls
                local wantClutter = cfg.includeClutterContainers and cfg.clutterAllItems
                local wantVase = cfg.includeVases and cfg.vaseAllItems
                if not (wantScroll or wantShelf or wantClutter or wantVase) then
                    stats.skippedConsumable = stats.skippedConsumable + 1 return
                end
                -- admitted ONLY because loot sources asked: those sources and nowhere else
                if not wantScroll then
                    scope = scopeSet({ bookshelf = wantShelf, clutter = wantClutter, vase = wantVase })
                end
            else
            local wantModded = cfg.includeConsumablesModded and not baseMod
            local wantBase = cfg.includeConsumablesBase and baseMod
            -- v0.9 (Alan): clutter containers may admit consumables LOCALLY, without the
            -- pool-wide toggle - the same shape wardrobes already use for cosmetics. The
            -- v0.8 answer (turn the Pool setting on for the user) was wrong: it made them
            -- pool-wide, so they appeared in chests and on corpses too.
            -- HISTORY: v0.9 restricted this to MODDED consumables, and only while neither Pool
            -- toggle was on, because the draw-time gate was per-CATEGORY and could not tell a
            -- vanilla potion from a modded one (reviews BL-2 and S-1: with 'modded ON / base
            -- OFF' the category gate stood open and a clutter-admitted VANILLA potion drew in
            -- chests). That is why Alan's barrels could never hold vanilla arrows.
            -- v1.0.1 (Alan, 2026-09-03): scoping is PER ENTRY (Main.lua entryAllowedFor), so
            -- clutter admits vanilla AND modded consumables and the flag below, not the
            -- category gate, keeps them out of every other container type.
            -- v1.1 (Alan, 2026-09-10): per CATEGORY and per source - barrels & crates and vases
            -- each admit a consumable when its own box (or "everything") is ticked.
            local box = MIR.ConsumableBox[category]
            local wantClutter = (cfg.includeClutterContainers
                and ((box and cfg["clutter" .. box]) or cfg.clutterAllItems)) and true or false
            local wantVase = (cfg.includeVases
                and ((box and cfg["vase" .. box]) or cfg.vaseAllItems)) and true or false
            if not (wantModded or wantBase or wantClutter or wantVase) then
                stats.skippedConsumable = stats.skippedConsumable + 1 return
            end
            -- admitted ONLY because a loot source asked: it can appear there and nowhere
            -- else. Load-bearing since v1.0.1; also reported by !mir_pool.
            if not (wantModded or wantBase) then
                scope = scopeSet({ clutter = wantClutter, vase = wantVase })
            end
            end
        end

        -- template + eligibility
        local rt = ""
        pcall(function() rt = tostring(stat.RootTemplate or "") end)
        if rt == "" then stats.skippedNoTemplate = stats.skippedNoTemplate + 1 return end
        if byTemplate[rt] or userExcluded[rt] or tableExcluded[rt] then stats.skippedDupe = stats.skippedDupe + 1 return end
        local tmpl = nil
        pcall(function() tmpl = Ext.Template.GetRootTemplate(rt) end)
        if not tmpl then stats.skippedNoTemplate = stats.skippedNoTemplate + 1 return end

        local story, key = false, false
        pcall(function() story = tmpl.StoryItem == true end)
        pcall(function() key = tmpl.IsKey == true end)
        if story or key then stats.skippedStory = stats.skippedStory + 1 return end

        local dn = ""
        pcall(function() dn = tostring(Ext.Loca.GetTranslatedString(tmpl.DisplayName.Handle.Handle) or "") end)
        if dn == "" then stats.skippedNoName = stats.skippedNoName + 1 return end

        -- internal template Name: the key treasure categories reference items by
        -- (NOT the stat name, NOT the uuid). Cached on the entry for the fence,
        -- the browser and !mir_tables.
        local tplName = ""
        pcall(function() tplName = tostring(tmpl.Name or "") end)

        local rarity = "Common"
        pcall(function()
            local r = tostring(stat.Rarity or "")
            if MIR.RarityOrder[r] then rarity = r end
        end)

        addEntry(statName, category, rarity, rt, modKey, dn, consumable, tplName, baseMod, scope)
        -- byTemplate[rt] is set only when addEntry actually admitted it, so this is the one
        -- place that can honestly say a listed key reached the pool (diff review S-5).
        if extraHit and byTemplate[rt] then
            for _, k in ipairs(extraHit) do extraMatched[k] = true end
            stats.extraAdmitted = (stats.extraAdmitted or 0) + 1
        end
    end

    for _, n in ipairs(Ext.Stats.GetStats("Armor")) do considerEntry(n, "Armor") end
    for _, n in ipairs(Ext.Stats.GetStats("Weapon")) do considerEntry(n, "Weapon") end
    for _, n in ipairs(Ext.Stats.GetStats("Object")) do considerEntry(n, "Object") end

    -- v1.1.2 (SF-13): say what the tightened scroll rule rejected. Expected to be empty or to
    -- name only mods that mis-set ItemUseType; if a real scroll shows up here, add "Scroll" to
    -- its name/category upstream or list it in the extra-items allow-list.
    if scrollRejectCount > 0 and MIR.Log then
        MIR.Log(("scroll rule: %d stat(s) claimed ItemUseType=Scroll with nothing else to"
            .. " corroborate it and were NOT catalogued as scrolls%s - %s")
            :format(scrollRejectCount,
                    scrollRejectCount > #scrollRejects
                        and (" (first %d shown)"):format(#scrollRejects) or "",
                    table.concat(scrollRejects, ", ")))
    end

    -- v1.1.2 (plan review SF-4): name every allow-list entry that is not in the pool, so a
    -- typo, an uninstalled mod or a name MIR cannot admit is visible instead of the feature
    -- silently doing nothing. Reported ONLY when the picture CHANGES (diff review S-6: a
    -- rebuild happens on every settings change, and this must not nag every time).
    do
        local missing, notes, n = {}, {}, 0
        for key in pairs(cfg.extraChestItems or {}) do
            n = n + 1
            if not extraMatched[key] then
                missing[#missing + 1] = tostring(key)
                if extraNote[key] then notes[#notes + 1] = tostring(key) .. " - " .. extraNote[key] end
            end
        end
        table.sort(missing)
        table.sort(notes)
        local admitted = stats.extraAdmitted or 0
        local sig = ("%d|%s|%s|%s"):format(admitted, table.concat(missing, "\31"),
                                           table.concat(notes, "\31"), tostring(n))
        if sig ~= lastExtraReportSig and MIR.Log then
            if admitted > 0 then
                MIR.Log(("extra-items list: %d of %d entr(ies) admitted to the pool, chests only")
                    :format(admitted, n))
            end
            if #missing > 0 then
                MIR.Log(("extra-items list: %d of %d entr(ies) are NOT in the pool - %s")
                    :format(#missing, n, table.concat(missing, ", ")))
                if #notes > 0 then
                    MIR.Log("        why: " .. table.concat(notes, "; "))
                else
                    MIR.Log("        nothing was catalogued under that name. Use the STAT NAME"
                        .. " exactly as the SPAWNED lines of this log print it, or a"
                        .. " root-template UUID. An entry also lands here when its item was"
                        .. " fenced out (a utility or NPC-gear mod), excluded by you, a"
                        .. " duplicate of a template already in the pool, a story or key item,"
                        .. " or has no template or display name (verification F-4).")
                end
            end
        end
        -- only latch it when a logger existed to print it (verification F-5): otherwise the
        -- one-shot would be consumed by a build that said nothing.
        if MIR.Log then lastExtraReportSig = sig end
    end

    MIR.Catalog = { built = true, pool = pool, byTemplate = byTemplate,
                    userExcluded = userExcluded, tableExcluded = tableExcluded,
                    stats = stats, builtMs = Ext.Utils.MonotonicTime() - t0 }
    return MIR.Catalog
end

-- Remove an already-spawned template from the live pool (ledger hydration + post-spawn).
function MIR.RemoveFromPool(tplId)
    local entry = MIR.Catalog.byTemplate and MIR.Catalog.byTemplate[tplId] or nil
    if not entry or entry.spawned then return end
    entry.spawned = true
    local slice = MIR.Catalog.pool[entry.category] and MIR.Catalog.pool[entry.category][entry.rarity] or nil
    if not slice then return end
    for i, e in ipairs(slice) do
        if e.template == tplId then
            slice[i] = slice[#slice]
            slice[#slice] = nil
            return
        end
    end
end

-- Per-mod breakdown of the FULL eligible catalog (byTemplate, spawned items
-- included) — the data source for growing the curated utility list. !mir_mods.
function MIR.ModBreakdown()
    if not MIR.Catalog.built then return { "catalog not built" } end
    local perMod = {} -- [modKey] = { total = n, cats = { [cat] = n } }
    for _, entry in pairs(MIR.Catalog.byTemplate) do
        local m = perMod[entry.mod]
        if not m then m = { total = 0, cats = {} } perMod[entry.mod] = m end
        m.total = m.total + 1
        m.cats[entry.category] = (m.cats[entry.category] or 0) + 1
    end
    local keys = {}
    for k in pairs(perMod) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = perMod[a].total, perMod[b].total
        if ta ~= tb then return ta > tb end
        return a < b
    end)
    local lines = { "MIR per-mod ELIGIBLE pool breakdown (" .. #keys .. " mods; full catalog incl. already-spawned)" }
    for _, k in ipairs(keys) do
        local m = perMod[k]
        local cats = {}
        for c in pairs(m.cats) do cats[#cats + 1] = c end
        table.sort(cats)
        local parts = {}
        for _, c in ipairs(cats) do parts[#parts + 1] = c .. "=" .. m.cats[c] end
        local name = modInfo(k).name or "?"
        lines[#lines + 1] = ("%-5d %s [%s] %s"):format(m.total, name, k, table.concat(parts, " "))
    end
    return lines
end

-- Per-mod breakdown of items a mod PLACES IN THE WORLD ITSELF (!mir_placed_mods).
-- These are the only mods whose items a player could ever obtain twice: once where
-- the mod puts them, once from MIR. Reading BOTH tableExcluded and the placed flag on
-- pooled entries matters: an item the user force-included is still placed by its mod,
-- it just is not fenced any more, and it must still be reported here.
function MIR.PlacedModsBreakdown()
    if not MIR.Catalog.built then return { "catalog not built" } end
    local perMod = {} -- [modKey] = { placed = n, pool = n, tables = { [name] = n } }
    local function slot(modKey)
        local m = perMod[modKey]
        if not m then m = { placed = 0, pool = 0, tables = {} } perMod[modKey] = m end
        return m
    end
    -- review S3: entry.placed is only ever set inside the toggle-gated fence branch, so with
    -- the filter OFF nothing carries it and this report would be silently empty - which is
    -- exactly the state in which a user most wants to know which mods double-dip. Recompute
    -- from the index instead. Cheap: HasTreasureDistribution is a hash lookup.
    local function isPlacedEntry(e)
        if e.placed then return true end
        -- MODDED, NON-CONSUMABLE only - same scope as the fence itself (review S7), and
        -- allow-list items are fence-exempt by construction (diff review S-3)
        if e.base or e.consumable or e.category == "extra" then return false end
        if not MIR.HasTreasureDistribution then return false end
        local ok, res = pcall(MIR.HasTreasureDistribution, e.stat, e.tplName)
        return (ok and res) and true or false
    end

    local function notePlaced(entry)
        local m = slot(entry.mod)
        m.placed = m.placed + 1
        if MIR.TreasureSourceOf then
            local ok, tbl = pcall(MIR.TreasureSourceOf, entry.stat, entry.tplName)
            if ok and tbl ~= nil and tbl ~= "" then
                local k = tostring(tbl)
                m.tables[k] = (m.tables[k] or 0) + 1
            end
        end
    end
    -- fenced-out placed items (only populated while the filter is ON)
    for _, e in pairs(MIR.Catalog.tableExcluded or {}) do notePlaced(e) end
    -- pooled items: placed ones are either force-included or the filter is off entirely
    for _, e in pairs(MIR.Catalog.byTemplate or {}) do
        if isPlacedEntry(e) then notePlaced(e) else slot(e.mod).pool = slot(e.mod).pool + 1 end
    end
    local keys = {}
    for k, m in pairs(perMod) do if m.placed > 0 then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b)
        local pa, pb = perMod[a].placed, perMod[b].placed
        if pa ~= pb then return pa > pb end
        return a < b
    end)
    local lines = {
        "MODS THAT PLACE THEIR OWN ITEMS IN THE GAME WORLD",
        "",
        "These are the only mods whose items you could ever obtain TWICE - once where the mod",
        "puts them, and once from MIR. By default MIR keeps such items out of its spawn pool so",
        "that cannot happen; this report is here so you can see which mods that affects.",
        "MIR never removes, replaces or suppresses anything a mod places - it only declines to",
        "spawn a second copy.",
        "",
        ("mods listed: %d"):format(#keys),
        ((MIR.TreasureIndex and MIR.TreasureIndex.partial)
            and "WARNING: the placement index is PARTIAL - these counts are INCOMPLETE. Re-run !mir_tables."
            or ((MIR.Config and MIR.Config.excludeTreasureTableItems)
                and "filter is ON - these items are currently excluded from MIR's spawn pool"
                or "filter is OFF - these items are currently IN MIR's spawn pool, so duplicates are possible")),
        "",
        ("%-7s %-6s %-46s %s"):format("placed", "pool", "mod", "most common source table"),
    }
    for _, k in ipairs(keys) do
        local m = perMod[k]
        local topTable, topN = "?", -1
        for name, n in pairs(m.tables) do
            if n > topN or (n == topN and name < topTable) then topTable, topN = name, n end
        end
        local name = (modInfo(k).name) or "?"
        lines[#lines + 1] = ("%-7d %-6d %-46s %s"):format(
            m.placed, m.pool, (name .. " [" .. tostring(k) .. "]"), topTable)
    end
    if #keys == 0 then
        lines[#lines + 1] = "(none - no mod in your load order places its own items where MIR can see it)"
    end
    return lines
end

-- Pool summary for !mir_pool
function MIR.PoolCounts()
    local lines = {}
    if not MIR.Catalog.built then return { "catalog not built" } end
    local grand = 0
    local cats = {}
    for cat in pairs(MIR.Catalog.pool) do cats[#cats + 1] = cat end
    table.sort(cats)
    for _, cat in ipairs(cats) do
        local parts, catTotal = {}, 0
        local byScope, scopeOrder = {}, {} -- [scope text] = n, in first-seen order
        for _, tier in ipairs(MIR.TierName) do
            local slice = MIR.Catalog.pool[cat][tier]
            local n = slice and #slice or 0
            catTotal = catTotal + n
            parts[#parts + 1] = tier .. "=" .. n
            for _, e in ipairs(slice or {}) do
                local st = MIR.ScopeText(e.scope)
                if st then
                    if not byScope[st] then byScope[st] = 0 scopeOrder[#scopeOrder + 1] = st end
                    byScope[st] = byScope[st] + 1
                end
            end
        end
        grand = grand + catTotal
        -- v1.0: say when a category is only LOCALLY admitted, so the count cannot be read
        -- as "generally available" (the clutterOnly flag was recorded since v0.9 but never
        -- reported - review MINOR).
        local scope = ""
        for _, st in ipairs(scopeOrder) do
            scope = scope .. ("  [%d drawable ONLY in %s]"):format(byScope[st], st)
        end
        lines[#lines + 1] = ("%-16s total=%-5d %s%s"):format(cat, catTotal, table.concat(parts, " "), scope)
    end
    lines[#lines + 1] = "GRAND TOTAL (live pool): " .. grand
    return lines
end

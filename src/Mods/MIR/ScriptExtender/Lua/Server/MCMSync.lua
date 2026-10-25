-- MIR MCM sync layer (Phase 3 chunk 2, design §1/§3.3).
-- One-way MCM -> MIR.Config. The engine keeps reading MIR.Config; MCM is a
-- SOURCE that writes into it. Loads BEFORE Main.lua so its SessionLoaded
-- subscriber runs first (settings applied before the catalog is built).
-- Degrades gracefully: with MCM absent the hardcoded Config defaults stand.
MIR = MIR or {}

local MCM_UUID = "755a8a72-407f-4f0d-9a33-274ac0f0b53d"

-- MIR.Log is assigned by Main.lua (loads after this file); fall back until then.
local function log(m)
    if MIR.Log then MIR.Log("[MCM] " .. tostring(m))
    else Ext.Utils.Print("[MIR][MCM] " .. tostring(m)) end
end

-- settingId -> config field + whether a pool rebuild is needed (design §3.3)
local SETTING_MAP = {
    { id = "mir_enabled",                    field = "enabled",                  rebuild = false, kind = "bool" },
    { id = "mir_base_chance",                field = "baseChancePct",            rebuild = false, kind = "int" },
    { id = "mir_rolls",                      field = "rolls",                    rebuild = false, kind = "int" },
    { id = "mir_include_corpses",            field = "includeCorpses",           rebuild = false, kind = "bool" },
    -- v1.1.1: the chest switch - draw-time (the treasure filter is unrestricted and scope-free)
    { id = "mir_include_chests",             field = "includeChests",            rebuild = false, kind = "bool" },
    -- v0.9: the clutter switch decides CATALOG COMPOSITION (consumables admitted for barrels), so
    -- it must rebuild. rebuild=false would leave it apparently doing nothing.
    { id = "mir_include_clutter",            field = "includeClutterContainers", rebuild = true,  kind = "bool" },
    -- v1.1 loot sources (the author, 2026-09-10): barrels & crates and vases/urns share one box shape.
    -- The consumable boxes and "everything" ADMIT items to the catalogue for that source
    -- (Catalog.lua), so they rebuild; rings are draw-time (equipment is always catalogued).
    -- mir_clutter_consumables_only is GONE from this map (plan 11.2): it survives only as a
    -- hidden blueprint setting, read once for the upgrade hint in SyncFromMCM.
    { id = "mir_clutter_rings",              field = "clutterRings",             rebuild = false, kind = "bool" },
    { id = "mir_clutter_potions",            field = "clutterPotions",           rebuild = true,  kind = "bool" },
    { id = "mir_clutter_arrows",             field = "clutterArrows",            rebuild = true,  kind = "bool" },
    { id = "mir_clutter_ingredients",        field = "clutterIngredients",       rebuild = true,  kind = "bool" },
    { id = "mir_clutter_all_items",          field = "clutterAllItems",          rebuild = true,  kind = "bool" },
    { id = "mir_include_vases",              field = "includeVases",             rebuild = true,  kind = "bool" },
    { id = "mir_vase_rings",                 field = "vaseRings",                rebuild = false, kind = "bool" },
    { id = "mir_vase_potions",               field = "vasePotions",              rebuild = true,  kind = "bool" },
    { id = "mir_vase_arrows",                field = "vaseArrows",               rebuild = true,  kind = "bool" },
    { id = "mir_vase_ingredients",           field = "vaseIngredients",          rebuild = true,  kind = "bool" },
    { id = "mir_vase_all_items",             field = "vaseAllItems",             rebuild = true,  kind = "bool" },
    -- v0.8 container classes + content filters: draw-time (rebuild = false).
    { id = "mir_include_wardrobes",          field = "includeWardrobes",         rebuild = false, kind = "bool" },
    { id = "mir_wardrobe_cosmetics",         field = "wardrobeCosmetics",        rebuild = false, kind = "bool" },
    { id = "mir_wardrobe_stat_garments",     field = "wardrobeStatGarments",     rebuild = false, kind = "bool" },
    { id = "mir_wardrobe_all_items",         field = "wardrobeAllItems",         rebuild = false, kind = "bool" },
    -- v1.0 bookshelves + scrolls. The class switch and the bookshelf-scrolls box both decide
    -- whether scrolls are ADMITTED to the catalogue (Catalog.lua Object branch), so they
    -- rebuild; "all items" is draw-time only (plan review BL-5).
    { id = "mir_include_bookshelves",        field = "includeBookshelves",       rebuild = true,  kind = "bool" },
    { id = "mir_bookshelf_scrolls",          field = "bookshelfScrolls",         rebuild = true,  kind = "bool" },
    { id = "mir_bookshelf_all_items",        field = "bookshelfAllItems",        rebuild = false, kind = "bool" },
    { id = "mir_include_scrolls",            field = "includeScrolls",           rebuild = true,  kind = "bool" },
    { id = "mir_exclude_nautiloid",          field = "excludeNautiloid",         rebuild = false, kind = "bool" },
    { id = "mir_notify_spawns",              field = "notifySpawns",             rebuild = false, kind = "bool" },
    { id = "mir_include_cosmetics",          field = "includeCosmetics",         rebuild = false, kind = "bool" }, -- draw-time gate
    { id = "mir_include_base_game",          field = "includeBaseGame",          rebuild = true,  kind = "bool" },
    { id = "mir_include_consumables_modded", field = "includeConsumablesModded", rebuild = true,  kind = "bool" },
    { id = "mir_include_consumables_base",   field = "includeConsumablesBase",   rebuild = true,  kind = "bool" },
    { id = "mir_exclude_utility_mods",       field = "excludeUtilityMods",       rebuild = true,  kind = "bool" },
    -- changes pool composition (fence applied at catalog build time) -> rebuild
    { id = "mir_exclude_treasure_items",     field = "excludeTreasureTableItems", rebuild = true, kind = "bool" },

    -- ===== v0.9 rarity window =====
    -- These write NESTED config (rarityWindow.levelRules[n].minTier), which a plain
    -- `field` cannot express: both application sites do `MIR.Config[field] = v`, a
    -- single-level assignment, and ApplyMcmSetting returns early for any id it does not
    -- know. A blueprint-only id would therefore apply NEVER, silently, on BOTH paths
    -- (review BL-1). Hence `apply`, honoured by SyncFromMCM and ApplyMcmSetting alike.
    { id = "mir_rarity_window_enabled", rebuild = false, kind = "bool",
      apply = function(v) MIR.Config.rarityWindow.enabled = v end },

    { id = "mir_rw_lvl1_min", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[1].minTier = v end },
    { id = "mir_rw_lvl1_max", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[1].maxTier = v end },
    { id = "mir_rw_lvl2_min", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[2].minTier = v end },
    { id = "mir_rw_lvl2_max", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[2].maxTier = v end },
    { id = "mir_rw_lvl3_min", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[3].minTier = v end },
    { id = "mir_rw_lvl3_max", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[3].maxTier = v end },
    { id = "mir_rw_lvl4_min", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[4].minTier = v end },
    { id = "mir_rw_lvl4_max", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.levelRules[4].maxTier = v end },

    { id = "mir_rw_act1_min", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.actRules[1].minTier = v end },
    { id = "mir_rw_act1_max", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.actRules[1].maxTier = v end },
    { id = "mir_rw_act2_min", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.actRules[2].minTier = v end },
    { id = "mir_rw_act2_max", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.actRules[2].maxTier = v end },
    { id = "mir_rw_act3_min", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.actRules[3].minTier = v end },
    { id = "mir_rw_act3_max", rebuild = false, kind = "tier",
      apply = function(v) MIR.Config.rarityWindow.actRules[3].maxTier = v end },
}

-- v0.9: one place that knows how to write a row, so `apply` cannot be honoured on one
-- path and forgotten on the other.
local function applySetting(m, v)
    if m.apply then m.apply(v) else MIR.Config[m.field] = v end
end

-- v0.9 (review Q7). MCM cannot express cross-setting validation, so min<=max is enforced
-- on READ. Direction matters: on a SINGLE-setting change the changed id is known, so clamp
-- the OTHER value - raising max back to min would undo the very drag the user just made and
-- read as a broken control. On a FULL sync there is no "last changed", so clamp max=min.
-- DELIBERATELY NOT written back through MCM.Set: v0.9 removes the last place MIR edited a
-- user setting and must not add a new one. Clamped in memory, logged once, and !mir_rarity
-- shows raw-vs-clamped so the MCM value never silently lies.
local rwNormWarned = false
function MIR.NormalizeRarityWindow(changedId)
    local rw = MIR.Config and MIR.Config.rarityWindow
    if not rw then return end
    local fixed = {}
    local function fixRule(rule, label, minId, maxId)
        if not rule then return end
        local mn = math.max(1, math.min(5, tonumber(rule.minTier) or 1))
        local mx = math.max(1, math.min(5, tonumber(rule.maxTier) or 5))
        if mn > mx then
            -- review S-2: keep the RAW pair so !mir_rarity can show what MCM still
            -- displays alongside what MIR is actually using. MCM is deliberately not
            -- rewritten, so without this the two views silently disagree forever.
            MIR.RarityClamps = MIR.RarityClamps or {}
            MIR.RarityClamps[label] = { rawMin = mn, rawMax = mx }
            if changedId == minId then mx = mn        -- user raised min: push max up
            elseif changedId == maxId then mn = mx    -- user lowered max: pull min down
            else mx = mn end                          -- full sync: no last-changed known
            fixed[#fixed + 1] = label
        end
        rule.minTier, rule.maxTier = mn, mx
        if MIR.RarityClamps and MIR.RarityClamps[label] then
            MIR.RarityClamps[label].useMin, MIR.RarityClamps[label].useMax = mn, mx
        end
    end
    for i, r in ipairs(rw.levelRules or {}) do
        fixRule(r, "level band " .. i, "mir_rw_lvl" .. i .. "_min", "mir_rw_lvl" .. i .. "_max")
    end
    for a = 1, 3 do
        fixRule((rw.actRules or {})[a], "Act " .. a, "mir_rw_act" .. a .. "_min", "mir_rw_act" .. a .. "_max")
    end
    if #fixed > 0 and not rwNormWarned then
        rwNormWarned = true
        log("rarity window: min was above max in " .. table.concat(fixed, ", ")
            .. " - clamped in memory (MCM is NOT rewritten). !mir_rarity shows the values in use.")
    end
end

-- v1.1 (the author, 2026-09-10): per-loot-source chance and rolls. One "use its own" box per source
-- shows two sliders (MCM VisibleIf). Draw-time only; nested config, hence `apply`.
for _, k in ipairs(MIR.SourceKeys) do
    SETTING_MAP[#SETTING_MAP + 1] = { id = "mir_own_" .. k, rebuild = false, kind = "bool",
        apply = function(v) MIR.Config.sourceOwn[k] = v end }
    SETTING_MAP[#SETTING_MAP + 1] = { id = "mir_chance_" .. k, rebuild = false, kind = "int",
        apply = function(v) MIR.Config.sourceChancePct[k] = math.max(0, math.min(100, v)) end }
    SETTING_MAP[#SETTING_MAP + 1] = { id = "mir_rolls_" .. k, rebuild = false, kind = "int",
        apply = function(v) MIR.Config.sourceRolls[k] = math.max(0, math.min(10, v)) end }
end

local SETTING_BY_ID = {}


for _, m in ipairs(SETTING_MAP) do SETTING_BY_ID[m.id] = m end

-- A category missing here has its weight silently reset to the default every session,
-- because this is what SyncFromMCM reads back (plan review BL-4). Must name every key in
-- Config.categoryWeights.
local SHARE_CATS = { "helmet", "gloves", "torso", "boots", "cloak", "ring", "amulet",
                     "weapon", "shield", "vanityClothing", "vanityBoots", "underwear",
                     "potion", "arrow", "alchemyIngredient", "scroll", "extra" }
local SHARE_BY_ID = {}
for _, cat in ipairs(SHARE_CATS) do SHARE_BY_ID["mir_share_" .. cat] = cat end

-- v1.0: the per-category include checkboxes (mir_cat_*) are DELETED - see Config.lua.
-- MCM drops the stale keys from settings.json on its own; nothing here reads them.

local LIST_IDS = {
    mir_excluded_mod_uuids = "excludedModUuids",
    -- v1.2.0: which of MIR's OWN defaults the user switched off. A TICKED element means that
    -- default is OFF (the list is "defaults you have turned off"), which reads as a double
    -- negative but reuses readListSetting - a path three reviews have hardened, which trims,
    -- honours the master tick and refuses to overwrite on a read error. Hidden in MCM.
    mir_default_off = "defaultExclusionOff",
    mir_excluded_templates = "excludedTemplates",
    mir_force_included_templates = "forceIncludedTemplates",
    mir_extra_chest_items = "extraChestItems", -- v1.1.2: chest-only allow-list
}

-- Console-override shadows (design §3.3/M4): console commands mark the MCM
-- setting they shadow; an explicit MCM save for that key wins and clears it;
-- full syncs clear all shadows.
MIR.ConsoleOverrides = {}
function MIR.MarkConsoleOverride(settingId)
    if settingId then MIR.ConsoleOverrides[settingId] = true end
end

MIR.McmDetected = false
-- MIR.McmMissing: the mod is DORMANT because MCM is not installed (the author, 2026-08-24:
-- "since MCM is a hard requirement we want the mod to refuse to run without it").
-- IMPORTANT distinction, and the reason there are two flags:
--   * mcmPakLoaded()  = is the BG3MCM pak in the load order? Authoritative, and
--     independent of Lua timing. This is what gates dormancy.
--   * MCM ~= nil      = has MCM injected its API into our env YET? The lifecycle
--     point is undocumented, so a nil global is NOT proof the user lacks MCM and
--     must never be allowed to disable the mod. That case keeps the existing
--     retry-and-defaults path.
MIR.McmMissing = false
local function mcmPakLoaded()
    -- A live MCM API is conclusive proof MCM is installed; no probe needed.
    if MCM ~= nil then return true end
    local ok, loaded = pcall(Ext.Mod.IsModLoaded, MCM_UUID)
    if not ok then
        -- INDETERMINATE, never fail closed (review #1): declaring a working
        -- install "MCM-less" would brick the mod for a user who did everything
        -- right, whereas assuming present merely restores v0.6.2 behaviour.
        log("Ext.Mod.IsModLoaded unavailable - assuming MCM present (not going dormant)")
        return true
    end
    return loaded == true
end
local function mcmPresent()
    return MCM ~= nil
end

-- Debounced rebuild (design §3.3): one rebuild per event burst. Falls back to
-- an immediate rebuild if the timer facility is unavailable.
local rebuildPending = false
function MIR.RequestMcmRebuild(tag)
    if rebuildPending then return end
    rebuildPending = true
    local ok = pcall(function()
        Ext.Timer.WaitFor(200, function()
            rebuildPending = false
            local ok2, err = pcall(function()
                if MIR.RebuildAndRehydrate then MIR.RebuildAndRehydrate("mcm:" .. tostring(tag)) end
            end)
            if not ok2 then log("debounced rebuild ERROR: " .. tostring(err)) end
        end)
    end)
    if not ok then
        rebuildPending = false
        if MIR.RebuildAndRehydrate then MIR.RebuildAndRehydrate("mcm-immediate:" .. tostring(tag)) end
    end
end

-- ---------------- live-event subscriptions ----------------
-- Per-event idempotent subscription with retry (review B2/M5): the MCM global
-- may not be injected at MIR's file-load time (lifecycle undocumented), and a
-- partial failure must not orphan the succeeded subscriptions. ensureSubscribed
-- is re-run from SyncFromMCM once MCM is provably present.
local subs = {}
local function trySub(eventName, handler)
    if subs[eventName] then return end
    subs[eventName] = pcall(function()
        Ext.ModEvents.BG3MCM[eventName]:Subscribe(handler)
    end)
end

local function onSettingSaved(p)
    if not p or p.modUUID ~= ModuleUUID or not p.settingId then return end
    local ok, err = pcall(function() MIR.ApplyMcmSetting(p.settingId, p.value) end)
    if not ok then log("ApplyMcmSetting ERROR: " .. tostring(err)) end
end
local function onSettingReset(p)
    if not p or p.modUUID ~= ModuleUUID or not p.settingId then return end
    -- v1.2.0: the third argument tells a reset from a save. Both arrive as an empty list for
    -- mir_exclusions, so without it Reset and Delete All are the same event. (In the MAIN MENU
    -- MCM emits nothing at all for a reset, so there they really are indistinguishable.)
    local ok, err = pcall(function() MIR.ApplyMcmSetting(p.settingId, p.defaultValue, true) end)
    if not ok then log("ApplyMcmSetting(reset) ERROR: " .. tostring(err)) end
end
local function onProfileActivated()
    local ok, err = pcall(function()
        log("MCM profile switch - full re-sync")
        -- The labels in memory belong to the OLD profile. Keeping them would make the new
        -- profile's (empty) list look like the user had deleted every row (diff review B3).
        MIR.ResetExclusionLabels()
        MIR.SyncFromMCM("profile")
        MIR.RequestMcmRebuild("profile")
    end)
    if not ok then log("profile re-sync ERROR: " .. tostring(err)) end
end

local function ensureSubscribed()
    trySub("MCM_Setting_Saved", onSettingSaved)
    trySub("MCM_Setting_Reset", onSettingReset)
    trySub("MCM_Profile_Activated", onProfileActivated)
end

local tierTypeWarned = false
local function coerce(kind, value)
    -- nil ALWAYS stays nil: an unreadable value must be SKIPPED, never applied
    -- (review B1: `value == true` coerced nil to false and silently overwrote
    -- true-default guards like enabled/excludeNautiloid).
    if kind == "bool" then
        if type(value) == "boolean" then return value end
        return nil
    end
    if kind == "int" then
        local n = tonumber(value)
        return n and math.floor(n) or nil
    end
    -- v0.9: rarity tier. The MCM control is an ENUM whose value is the rarity NAME
    -- ("Common".."Legendary"); a number is accepted too so a console setter or a
    -- hand-edited settings file still works. Anything unrecognised stays nil, which
    -- means SKIP - never silently coerce to a tier the user did not choose.
    if kind == "tier" then
        -- MCM enum values are the CHOICE STRING. If a build ever hands back an index
        -- instead, blindly clamping it would shift every tier silently (a 0-based index
        -- would put Uncommon at Common), and AuditSettingIds would still say "OK" because
        -- it only tests for non-nil. Say so once rather than quietly mis-setting the window.
        if type(value) ~= "string" and not tierTypeWarned then
            tierTypeWarned = true
            log("rarity: MCM returned a " .. type(value) .. " for a tier setting, not the choice"
                .. " name. Treating it as a 1-5 tier number - verify with !mir_rarity.")
        end
        if type(value) == "string" then
            local t = MIR.RarityOrder and MIR.RarityOrder[value]
            if t then return t end
            local n = tonumber(value)
            if n then return math.max(1, math.min(5, math.floor(n))) end
            return nil
        end
        local n = tonumber(value)
        if not n then return nil end
        return math.max(1, math.min(5, math.floor(n)))
    end

    return value
end

-- Returns set, ok. On a read ERROR, ok=false and the caller must SKIP the
-- assignment (review S3: never wipe real user exclusions on a transient failure).
local function readListSetting(settingId)
    local set = {}
    local ok = pcall(function()
        local t = MCM.List.GetEnabled(settingId)
        for name, enabled in pairs(t or {}) do
            -- v1.1.2 BLOCKER (diff review B-1, plan review SF-10): TRIM. MCM's list editor
            -- stores whatever was typed or pasted, trailing space included, and every
            -- consumer matches EXACTLY (Catalog allow-list, template uuids, mod uuids). An
            -- untrimmed key can never match, and the extra-items diagnostic would then
            -- report a visually identical entry as "matched nothing". The console path
            -- already trims (Browser.lua), so without this the two routes disagreed.
            if enabled then
                set[(tostring(name):gsub("^%s+", ""):gsub("%s+$", ""))] = true
            end
        end
    end)
    return set, ok
end

-- ---------------- read-only curated-exclusion views ----------------
-- (the author, 2026-08-21: "list anything that is excluded there, including things
-- that are toggled excluded.") Two ReadOnly list_v2 settings on the Exclusion
-- lists tab mirror the mod-level curated fences, filtered to mods PRESENT in
-- the load order, by readable name. Never read back; published via MCM.Set
-- with shouldEmitEvent=false (their ids are not in our maps anyway).
local function modDisplayName(uuid)
    local name = nil
    pcall(function()
        local m = Ext.Mod.GetMod(uuid)
        if m and m.Info then name = tostring(m.Info.Name or "") end
    end)
    if not name or name == "" then return nil end
    return (name:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function buildElements(uuidSet, nameSet, enabledFlag)
    local elems, seen = {}, {}
    local function add(uuid, name)
        if seen[uuid] then return end
        seen[uuid] = true
        elems[#elems + 1] = { name = (name or "?") .. "  [" .. tostring(uuid):sub(1, 8) .. "]", enabled = enabledFlag }
    end
    for uuid in pairs(uuidSet) do
        local loaded = false
        pcall(function() loaded = Ext.Mod.IsModLoaded(uuid) end)
        if loaded then add(uuid, modDisplayName(uuid)) end
    end
    -- byName-fenced mods (review S2): walk the load order once; trivial cost
    if nameSet then
        pcall(function()
            for _, uuid in ipairs(Ext.Mod.GetLoadOrder() or {}) do
                local name = modDisplayName(uuid)
                if name and nameSet[name] then add(uuid, name) end
            end
        end)
    end
    table.sort(elems, function(a, b) return a.name < b.name end)
    return elems
end

-- MCM.Set returns boolean; the runtime list shape is lowercase
-- (enabled/elements/name) per MCM's ListV2Validator (review M1: no other shape passes).
local function setListValue(settingId, elems)
    local ok, r = pcall(function()
        return MCM.Set(settingId, { enabled = true, elements = elems }, ModuleUUID, false)
    end)
    if ok and r ~= false then return true, "ok" end
    return false, tostring(r)
end

-- ============================================================================
-- v1.2.0 - THE ONE VISIBLE EXCLUSION LIST (mir_exclusions)
--
-- the author, 2026-10-19/21: one list, every row a readable mod name, including the two that used to
-- show as bare UUIDs, ticks that actually do something, defaults still excluded.
--
-- The list stores NOTHING. It is rebuilt from the two stores on every publish, and a tick in it
-- is translated back into a store write. That is deliberate: a stored tick could disagree with
-- the store it is supposed to represent, and an 8-character label fragment cannot reconstruct
-- the uuid Catalog.lua tests. The stores are unchanged - the user's exclusions still live in
-- mir_excluded_mod_uuids as raw uuids, read by readListSetting through LIST_IDS exactly as
-- before - that read is what LOADS them every session, and the only writers are this
-- file's wantState and Browser.lua's applyOne, both of which keep MIR.Config in step.
-- ============================================================================

-- What the last publish put on screen: label -> rule, so a tick can be translated, and the
-- label set, so a row's ABSENCE can be told from a row MIR never published.
--   `pending` holds labels MIR has added since the user's page was last seen to agree with it.
--   An open MCM page writes back its own cached array, so a row added after it was drawn looks
--   exactly like a row the user deleted - and deleting it would wipe real state. A pending
--   label is therefore never read as a deletion until an incoming array proves the page has
--   caught up (diff review B4).
-- This table is MEMORY ONLY and the server Lua state restarts with every save load, so
-- primeLabels() below rebuilds it from state when it is empty (diff review B1).
local lastPublished = { byLabel = {}, labels = {}, pending = {} }

local function modName(uuid)
    local nm = modDisplayName(uuid)
    if nm == nil or nm == "" then return nil end
    return nm
end

-- Build the rows from state. Returns elements, label->rule, and how many legacy rows it
-- included (so the caller knows whether a seed prune is due).
local function buildExclusionRows(includeLegacy, legacyUuids)
    local rows, byLabel, legacyShown = {}, {}, 0
    local labelCount = {}
    local function add(label, rule, enabled)
        if label == nil or label == "" then return end
        -- a second row with the same text would share the widget's id and toggle
        -- unpredictably, so disambiguate with the uuid head - but only when it happens
        if labelCount[label] then
            label = ("%s  [%s]"):format(label, tostring(rule.id):sub(1, 8))
        end
        labelCount[label] = true
        rows[#rows + 1] = { name = label, enabled = enabled and true or false }
        byLabel[label] = rule
    end

    -- 1. MIR's own defaults, FIRST so a default's state always wins the dedupe, and ticked as
    --    a pure function of the store - never "unconditionally ticked", which could show a
    --    ticked row while the store said off.
    local defaultKeyOfUuid = {}
    for _, r in ipairs(MIR.DefaultExclusions or {}) do
        local off = MIR.Config.defaultExclusionOff and MIR.Config.defaultExclusionOff[r.key]
        local label = r.label
        if r.kind == "mod" then
            defaultKeyOfUuid[r.id] = r.key
            local nm = modName(r.id)
            if nm == nil then label = label .. "  (not installed)" end
        end
        add(label, r, not off)
    end

    -- 2. the user's own excluded mods, except any that is already a default row.
    --    SORTED, because pairs() order would otherwise vary between sessions: two installed
    --    mods sharing a display name would swap which one owns the plain label and which gets
    --    the uuid suffix, so a main-menu untick could be applied to the wrong mod - and the
    --    "skip the write when the rows match" test would fail every session for nothing.
    local userUuids = {}
    for uuid in pairs(MIR.Config.excludedModUuids or {}) do
        if not defaultKeyOfUuid[uuid] then userUuids[#userUuids + 1] = uuid end
    end
    table.sort(userUuids, function(a, b)
        local na, nb = modName(a) or tostring(a), modName(b) or tostring(b)
        if na ~= nb then return na < nb end
        return tostring(a) < tostring(b)
    end)
    for _, uuid in ipairs(userUuids) do
        local nm = modName(uuid)
        add(nm or (tostring(uuid) .. "  (not installed)"),
            { kind = "user", id = uuid }, true)
    end

    -- 3. once, on the upgrade: the unticked leftovers of the old raw list, named, so the user
    --    can see what they were and decide. Ticking one makes it a real exclusion; leaving it
    --    unticked drops it, because an unticked element excludes nothing.
    if includeLegacy then
        for _, uuid in ipairs(legacyUuids or {}) do
            if not defaultKeyOfUuid[uuid] and not (MIR.Config.excludedModUuids or {})[uuid] then
                local nm = modName(uuid)
                add(nm or (tostring(uuid) .. "  (not installed)"),
                    { kind = "user", id = uuid }, false)
                legacyShown = legacyShown + 1
            end
        end
    end
    return rows, byLabel, legacyShown
end

local function readRawList(settingId)
    local v = nil
    local ok = pcall(function()
        if MCM.List and MCM.List.GetRaw then v = MCM.List.GetRaw(settingId)
        else v = MCM.Get(settingId) end
    end)
    if not ok or type(v) ~= "table" then return nil end
    return v
end

-- Element-wise comparison, tolerant of a hand-edited settings.json: a non-table element must
-- read as "different", never throw (this runs outside a pcall through PublishCuratedLists).
local function sameRows(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if type(x) ~= "table" or type(y) ~= "table" then return false end
        if x.name ~= y.name or (x.enabled and true or false) ~= (y.enabled and true or false) then
            return false
        end
    end
    return true
end

-- Write a whole store from a set of keys. FULL VALUE, deliberately, rather than per-key
-- MCM.List.SetEnabled: MCM hands a mod the BLUEPRINT DEFAULT table by reference for any setting
-- the profile has never stored, and SetEnabled mutates its argument in place - so the first
-- per-key write to a never-stored list scribbles on the shared default and the keys then leak
-- into every other profile that has not stored one either (diff review B3). A full-value
-- MCM.Set always installs a fresh table. Both stores are small (14 rules, a handful of mods).
-- NOTE for a future edit: this writes only the TICKED keys, so it also drops any unticked
-- leftovers in the store. That is wanted - an unticked element excludes nothing - but it means
-- the one-time legacy view must have been published BEFORE a store write lands. It has: the
-- legacy rows are read and published in PublishCuratedLists, which runs before any user edit
-- can reach ReconcileExclusions.
local function writeStore(settingId, keySet)
    local elems = {}
    for k in pairs(keySet or {}) do elems[#elems + 1] = { name = k, enabled = true } end
    table.sort(elems, function(a, b) return a.name < b.name end)
    local ok, res = pcall(function()
        return MCM.Set(settingId, { enabled = true, elements = elems }, ModuleUUID, false)
    end)
    if not ok or res == false then
        log(("exclusion write FAILED for %s (%s) - nothing changed"):format(settingId, tostring(res)))
        return false
    end
    return true
end

-- The rows are a pure function of the two stores, so the label -> rule map can always be
-- rebuilt rather than remembered. Used when the in-memory map is empty, which is EVERY session
-- start - without this, an edit made at the main menu could not be translated and would be
-- republished over (diff review B1).
-- Forget what was on screen. Called on a profile switch, where the labels in memory belong
-- to the profile being left.
function MIR.ResetExclusionLabels()
    lastPublished.byLabel = {}
    lastPublished.labels = {}
    lastPublished.pending = {}
end

local function primeLabels()
    if next(lastPublished.byLabel) ~= nil then return end
    local seeded = nil
    pcall(function() seeded = MCM.Get("mir_exclusions_seeded") end)
    local legacy = {}
    if seeded ~= true then
        local raw = readRawList("mir_excluded_mod_uuids")
        for _, el in ipairs((raw and raw.elements) or {}) do
            if el and el.name and not el.enabled then legacy[#legacy + 1] = tostring(el.name) end
        end
    end
    local rows, byLabel = buildExclusionRows(seeded ~= true, legacy)
    lastPublished.byLabel = byLabel
    lastPublished.labels = {}
    for _, r in ipairs(rows) do lastPublished.labels[#lastPublished.labels + 1] = r.name end
    -- nothing is "pending" on a cold start: the page the user edited was drawn from these rows
end

-- Translate what the user did in the visible list into store writes. Called from
-- ApplyMcmSetting (an in-game edit) AND from SyncFromMCM (an edit made at the main menu, where
-- there is no server context at all and MCM writes locally - without this, every main-menu edit
-- would be reverted at load).
function MIR.ReconcileExclusions(isReset)
    if not MIR.McmDetected then return false end
    local stored = readRawList("mir_exclusions")
    if stored == nil then
        log("mir_exclusions unreadable - leaving every exclusion as it is")
        return false
    end
    -- A cold start has nothing in memory, so a difference found now is just MIR learning the
    -- stored state - not the user moving anything. SessionLoaded builds the catalogue straight
    -- after this, so asking for a rebuild here would only build it twice.
    local coldStart = (next(lastPublished.byLabel) == nil)
    primeLabels()
    -- The master tick is read, never written: re-ticking it must restore every row untouched.
    -- A change to it has to force the rebuild by itself, because MCM pushes the SAME element
    -- array when the master box moves, so no row comparison below would notice (diff review
    -- B2) - and the fence only re-reads this at catalogue build time.
    local masterWas = (MIR.Config.defaultExclusionsEnabled ~= false)
    MIR.Config.defaultExclusionsEnabled = (stored.enabled ~= false)
    local masterMoved = (not coldStart) and (masterWas ~= (stored.enabled ~= false))

    if isReset then
        local had = next(MIR.Config.defaultExclusionOff or {}) ~= nil
        MIR.Config.defaultExclusionOff = {}
        local okAll = (not had) or writeStore("mir_default_off", MIR.Config.defaultExclusionOff)
        pcall(function() MCM.Set("mir_exclusions_seeded", false, ModuleUUID, false) end)
        log("exclusion list reset - every MIR default is on again" .. (okAll and "" or " (the write FAILED)"))
        MIR.PublishCuratedLists()
        MIR.RequestMcmRebuild("mir_exclusions")
        return true
    end

    local incoming = stored.elements
    if type(incoming) ~= "table" then return false end
    local seeded = nil
    pcall(function() seeded = MCM.Get("mir_exclusions_seeded") end)

    -- Honour a row's ABSENCE only when every incoming label is one MIR published. An open MCM
    -- page writes back its own cached array, so a row MIR added after the page was drawn is
    -- missing from it - and treating that as a deletion would wipe a real user exclusion.
    local seen, labelsKnown, unknown = {}, true, 0
    for _, el in ipairs(incoming) do
        local label = (type(el) == "table") and el.name or nil
        if type(label) == "string" then
            seen[label] = (el.enabled and true or false)
            if lastPublished.byLabel[label] == nil then labelsKnown = false unknown = unknown + 1 end
            -- the page has caught up with this row, so it may be read as a deletion from now on
            lastPublished.pending[label] = nil
        end
    end
    -- Delete All, but ONLY once MIR has published at least once into this profile. A brand-new
    -- MCM profile has an empty list and seeded=false while the previous profile's labels are
    -- still in memory - reading that as Delete All switched every default off (diff review B3).
    local deleteAll = (#incoming == 0) and (#lastPublished.labels > 0) and (seeded == true)

    -- Collect first, write once per store at the end: one MCM.Set each rather than up to 15
    -- settings-file writes, and no half-applied state if one write fails.
    local changed, touchUser, touchDefaults, skippedPending = 0, false, false, 0
    local function wantState(rule, on)
        if rule.kind == "user" then
            local has = (MIR.Config.excludedModUuids or {})[rule.id] and true or false
            if has ~= on then
                MIR.Config.excludedModUuids[rule.id] = on and true or nil
                touchUser = true
                changed = changed + 1
            end
        else
            local offNow = (MIR.Config.defaultExclusionOff or {})[rule.key] and true or false
            local offWanted = not on
            if offNow ~= offWanted then
                MIR.Config.defaultExclusionOff[rule.key] = offWanted and true or nil
                touchDefaults = true
                changed = changed + 1
            end
        end
    end

    for label, on in pairs(seen) do
        local rule = lastPublished.byLabel[label]
        if rule then wantState(rule, on)
        else log("exclusion list: ignoring an entry MIR does not recognise - " .. tostring(label)) end
    end
    -- `#incoming > 0` is load-bearing. `labelsKnown` starts true and is only falsified INSIDE
    -- the loop above, so an EMPTY array left it true - and with primeLabels() now rebuilding the
    -- label set from state, that read as "the user deleted every row" and switched all fourteen
    -- defaults off before the first catalogue build, on a fresh install, a fresh MCM profile and
    -- the first load of this build. An empty array may now only be honoured through deleteAll,
    -- which requires this profile to have been published into at least once.
    if deleteAll or (labelsKnown and #incoming > 0) then
        -- A label MIR published that is no longer there was deleted with the X (or by Delete
        -- All), which means the same as unticking it - unless MIR itself added that row after
        -- the user's page was drawn, in which case its absence is the stale page talking.
        for _, label in ipairs(lastPublished.labels) do
            if seen[label] == nil then
                if lastPublished.pending[label] then
                    -- MIR added this row after the page was drawn, so its absence is the stale
                    -- page talking, not a deletion. Keeping it is the safe side: ignoring a
                    -- deletion is recoverable, deleting an exclusion the user never touched is
                    -- not. Say so, and republish so storage still matches what MIR enforces.
                    skippedPending = skippedPending + 1
                else
                    local rule = lastPublished.byLabel[label]
                    if rule then wantState(rule, false) end
                end
            end
        end
    end
    if skippedPending > 0 then
        log(("exclusion list: %d row(s) MIR had just added were missing from the page MCM sent" ..
             " - left alone. Leave the Exclusions and overrides tab and come back, then try again."):format(
            skippedPending))
    end
    local wrote = true
    if touchUser then wrote = writeStore("mir_excluded_mod_uuids", MIR.Config.excludedModUuids) and wrote end
    if touchDefaults then wrote = writeStore("mir_default_off", MIR.Config.defaultExclusionOff) and wrote end
    -- An entry MIR does not recognise (someone typed one in) has to be published away, or the
    -- unknown label would keep disabling the deletion rule for good (diff review S1).
    if changed > 0 or masterMoved or unknown > 0 or skippedPending > 0 then
        if changed > 0 then log(("exclusion list: %d change(s) applied%s"):format(
            changed, wrote and "" or " (a store write FAILED)")) end
        if masterMoved then
            log("exclusion list: the box above the list is now " ..
                (MIR.Config.defaultExclusionsEnabled and "ON - MIR's own list applies again"
                 or "OFF - MIR uses every mod on its list"))
        end
        MIR.PublishCuratedLists()
        -- On a cold start SessionLoaded builds the catalogue immediately after this, so asking
        -- for another one here would build it twice. The publish still has to happen: it is what
        -- puts the user's main-menu edit back on screen correctly.
        if not coldStart then MIR.RequestMcmRebuild("mir_exclusions") end
    end
    return true
end

function MIR.PublishCuratedLists()
    if not MIR.McmDetected then return end
    local u = buildElements(MIR.UtilityMods.byUuid, MIR.UtilityMods.byName, MIR.Config.excludeUtilityMods == true)
    local n = buildElements(MIR.NpcGearMods.byUuid, nil, true)
    local okU, infoU = setListValue("mir_view_utility_excluded", u)
    local okN, infoN = setListValue("mir_view_npcgear_excluded", n)

    -- v1.2.0: the one editable exclusion list. Its rows are a pure function of the two stores,
    -- so publishing can never contradict them.
    local seeded = nil
    pcall(function() seeded = MCM.Get("mir_exclusions_seeded") end)
    local legacy = {}
    if seeded ~= true then
        -- the unticked leftovers of the old raw list: shown once, named, so the user can see
        -- what they were (the author's two bare-uuid rows), then pruned because they exclude nothing
        local raw = readRawList("mir_excluded_mod_uuids")
        for _, el in ipairs((raw and raw.elements) or {}) do
            if el and el.name and not el.enabled then legacy[#legacy + 1] = tostring(el.name) end
        end
    end
    local rows, byLabel, legacyShown = buildExclusionRows(seeded ~= true, legacy)
    local storedEx = readRawList("mir_exclusions")
    local masterEnabled = not (storedEx and storedEx.enabled == false)
    local okE, infoE = true, "unchanged"
    -- Skip the write when the rows already match: it saves a settings-file write and a net
    -- broadcast on every sync. The master tick needs no comparison here because MIR never
    -- changes it - it is read from the stored value just above.
    if not (storedEx and sameRows(storedEx.elements, rows)) then
        local ok2, res2 = pcall(function()
            return MCM.Set("mir_exclusions", { enabled = masterEnabled, elements = rows },
                           ModuleUUID, false)
        end)
        okE = (ok2 and res2 ~= false)
        infoE = okE and "published" or tostring(res2)
    end
    if okE then
        -- any row that is NEW to this publish is "pending": the user's open page cannot know
        -- about it yet, so its absence from an incoming array must not read as a deletion
        local wasPublished = {}
        for _, label in ipairs(lastPublished.labels) do wasPublished[label] = true end
        lastPublished.byLabel = byLabel
        lastPublished.labels = {}
        for _, r in ipairs(rows) do
            lastPublished.labels[#lastPublished.labels + 1] = r.name
            if not wasPublished[r.name] then lastPublished.pending[r.name] = true end
        end
        local stillThere = {}
        for _, label in ipairs(lastPublished.labels) do
            if lastPublished.pending[label] then stillThere[label] = true end
        end
        lastPublished.pending = stillThere
        if seeded ~= true then
            -- The inert leftovers of the old raw list are on screen now, so tidy them out of
            -- storage - but only mark the seeding done once that write is CONFIRMED, or a
            -- failure would burn the one-time view and leave the elements behind for good
            -- (diff review S2).
            local prunedOk = true
            if legacyShown > 0 then
                prunedOk = writeStore("mir_excluded_mod_uuids", MIR.Config.excludedModUuids)
                if prunedOk then
                    log(("exclusion list: showed %d inactive entr(ies) from your old list by name, and tidied them out of storage"):format(legacyShown))
                else
                    log("exclusion list: could not tidy the inactive entries out of storage - will retry next time")
                end
            end
            if prunedOk then
                pcall(function() MCM.Set("mir_exclusions_seeded", true, ModuleUUID, false) end)
            end
        end
    end
    log(("curated views: utility %d mod(s) %s; npc-gear %d mod(s) %s; exclusion list %d row(s) %s"):format(
        #u, okU and "published" or ("FAILED: " .. infoU),
        #n, okN and "published" or ("FAILED: " .. infoN),
        #rows, infoE))
end

-- Live shares are rendered by the MIR Browser tab (client IMGUI) as text above
-- real sliders. The old blueprint list_v2 readout was removed 2026-08-21: MCM's
-- "ReadOnly" lists keep clickable checkboxes, so a display-only list reads as a
-- broken control (the author: "the checkmark boxes ... cannot be unchecked").
-- Push the recomputed shares to the MIR Browser tab, which is now the ONLY UI
-- for category shares. Still needed after the raw tab was deleted: !mir_share, MCM
-- profile switches, container/pool toggles (v1.0: they drive the ON/LIMITED/OFF status) and pool rebuilds all change the numbers
-- behind the tab's back (the author, 2026-08-24: the menus "don't update each other"). Debounced because slider events arrive per
-- drag tick.
local sharesPushPending = false
function MIR.PublishShares()
    if sharesPushPending then return end
    sharesPushPending = true
    local ok = pcall(function()
        Ext.Timer.WaitFor(200, function()
            sharesPushPending = false
            pcall(function()
                if MIRNet and MIRNet.Notice and MIR.SharesPayload then
                    MIRNet.Notice:Broadcast({ kind = "shares", shares = MIR.SharesPayload() })
                end
            end)
        end)
    end)
    if not ok then
        sharesPushPending = false
        pcall(function()
            if MIRNet and MIRNet.Notice and MIR.SharesPayload then
                MIRNet.Notice:Broadcast({ kind = "shares", shares = MIR.SharesPayload() })
            end
        end)
    end
end

-- Full sync: read every MCM value into MIR.Config. Does NOT rebuild the
-- catalog itself — callers decide (SessionLoaded lets Main's builder run
-- after; !mir_mcm_sync and profile switches request a rebuild).
-- v0.9 (review BL-1): a typo in a setting id is otherwise a SILENT no-op on BOTH the
-- full-sync and live-change paths - MCM would happily hold a value MIR never reads.
-- Report any id MCM does not recognise, once, loudly.
local auditDone, legacyHintDone = false, false
function MIR.AuditSettingIds()
    if not (MCM and MCM.Get) then return end
    local missing, n = {}, 0
    for _, m in ipairs(SETTING_MAP) do
        n = n + 1
        local ok, v = pcall(function() return MCM.Get(m.id) end)
        if not ok or v == nil then missing[#missing + 1] = m.id end
    end
    -- v1.0: the share ids too (second plan review SF-8) - a category whose mir_share_* is
    -- missing from the blueprint would otherwise reset to its default every session, silently.
    for id in pairs(SHARE_BY_ID) do
        n = n + 1
        local ok, v = pcall(function() return MCM.Get(id) end)
        if not ok or v == nil then missing[#missing + 1] = id end
    end
    -- v1.1.2 (diff review S-2): list ids are deliberately NOT probed here. Nothing in this
    -- mod has ever read a list_v2 through MCM.Get - lists use MCM.List.GetEnabled - so a nil
    -- return would mean "wrong accessor", not "unknown id", and this audit would print the
    -- AUDIT FAILED banner naming three shipped, working exclusion lists. That banner is the
    -- mod's whole support surface; a false one is worse than the gap. What a mistyped list id
    -- actually does (verification F-6, correcting an earlier wording here): readListSetting
    -- returns an EMPTY set with ok=true, so Config holds nothing and the extra-items report
    -- says nothing either - it is silent in the log until someone WRITES, at which point
    -- MCM.List.SetEnabled returns false and Browser.lua logs "SetEnabled FAILED". It is also
    -- visible on inspection: !mir_status, !mir_extra and the MIR Browser show an empty list
    -- while MCM's own UI shows entries. To restore the loop, first confirm the accessor in
    -- game with one console line (server):
    --     Ext.Utils.Print(type(MCM.Get("mir_excluded_templates")))
    if #missing > 0 then
        log("SETTING ID AUDIT FAILED - MCM does not know: " .. table.concat(missing, ", "))
        log("        those settings can NEVER apply. Check MCM_blueprint.json against SETTING_MAP / SHARE_CATS.")
    else
        log(("setting id audit OK (%d settings all resolved)"):format(n))
    end
end

function MIR.SyncFromMCM(reason)
    if not mcmPakLoaded() then
        -- Hard dependency missing: go dormant rather than injecting items the user
        -- has no way to configure or switch off.
        MIR.McmDetected = false
        MIR.McmMissing = true
        log("=====================================================================")
        log("MCM (Mod Configuration Menu) IS NOT INSTALLED.")
        log("MCM is a hard requirement for MIR, which has DISABLED ITSELF: no items")
        log("will be added to any container or corpse this session.")
        log("Install Mod Configuration Menu (Nexus 9162) and load it ABOVE MIR.")
        log("=====================================================================")
        return false
    end
    if not mcmPresent() then
        -- Pak is present but the API has not been injected yet: transient, not a
        -- user error. Keep the defaults and let ensureSubscribed/retry catch up.
        MIR.McmDetected = false
        log("MCM pak loaded but its API is not available yet - defaults active for now ("
            .. tostring(reason) .. ")")
        return false
    end
    MIR.McmMissing = false -- only cleared once MCM is provably usable (review #5)
    MIR.McmDetected = true
    ensureSubscribed() -- retry live-event hookup now that MCM is provably up (review B2)
    local applied, shadowed = 0, 0
    for _, m in ipairs(SETTING_MAP) do
        local v = nil
        pcall(function() v = MCM.Get(m.id) end)
        v = coerce(m.kind, v)
        if v ~= nil then
            if MIR.ConsoleOverrides[m.id] then
                shadowed = shadowed + 1
                log("console override on " .. m.id .. " replaced by MCM value (full sync)")
            end
            MIR.ConsoleOverrides[m.id] = nil -- per-key clear: only when actually applied (review S2)
            -- review S-3: the rarity rows write NESTED config through closures. A throw
            -- here would abort every remaining row, the clamp, the shares loop and the
            -- list loop - on a path whose result the caller discards. Isolate each row.
            local okA, errA = pcall(applySetting, m, v)
            if okA then applied = applied + 1
            else log("apply FAILED for " .. tostring(m.id) .. ": " .. tostring(errA)) end
        end
    end
    -- v0.9: clamp after the whole map is applied, so a band and its Act are both current.
    if MIR.NormalizeRarityWindow then MIR.NormalizeRarityWindow(nil) end
    for id, cat in pairs(SHARE_BY_ID) do
        local v = nil
        pcall(function() v = MCM.Get(id) end)
        v = coerce("int", v)

        if v ~= nil then
            MIR.Config.categoryWeights[cat] = v
            applied = applied + 1
        end
    end
    for id, field in pairs(LIST_IDS) do
        local set, ok = readListSetting(id)
        if ok then MIR.Config[field] = set
        else log("list read FAILED for " .. id .. " - keeping current exclusions") end
    end
    log(("synced %d settings from MCM (%s)%s"):format(applied, tostring(reason),
        shadowed > 0 and (" - " .. shadowed .. " console override(s) replaced") or ""))
    -- v0.9: run the id audit ONCE, after a real sync has proven MCM is answering.
    if not auditDone then auditDone = true pcall(MIR.AuditSettingIds) end
    -- v1.1 (delta review SF-B): "Clutter containers: consumables only" is gone. Its id is kept as
    -- a hidden blueprint setting purely so MCM does not delete the stored value; if the user had
    -- it OFF (v1.0 unrestricted barrels), say what changed and what to tick. Never written.
    -- Diff review SF-1: the Lua state restarts with every save load, so a session flag alone
    -- would repeat this forever and the user could never silence it. It is therefore shown
    -- only while the barrel boxes are still at their shipped defaults - touching any of them
    -- (the thing the note asks for) stops it.
    if not legacyHintDone then
        legacyHintDone = true
        local cfg = MIR.Config
        local untouched = cfg.clutterPotions and cfg.clutterArrows and cfg.clutterIngredients
                          and not cfg.clutterRings and not cfg.clutterAllItems
        local old = nil
        pcall(function() old = MCM.Get("mir_clutter_consumables_only") end)
        if old == false and untouched then
            log("UPGRADE NOTE: you had 'Clutter containers: consumables only' OFF (barrels could give any item).")
            log("        v1.1 replaces it with tick boxes under Loot Source Settings > Barrels, crates and other")
            log("        clutter. Barrels now give only what is ticked (default: potions, arrows, ingredients).")
            log("        Tick 'everything' for gear again - it also admits scrolls and camp clothing there,")
            log("        whatever the Pool tab says. (This note stops once you change any of those boxes.)")
        end
    end
    -- v1.2.0: pick up anything the user changed in the visible list while there was no server
    -- context - at the main menu MCM writes its settings locally and MIR never hears an event,
    -- so this is the only chance to see those edits. It must run BEFORE the publish, which
    -- would otherwise rebuild the list from the stores and discard them.
    local okR, errR = pcall(function() MIR.ReconcileExclusions(false) end)
    if not okR then log("ReconcileExclusions ERROR: " .. tostring(errR)) end
    MIR.PublishCuratedLists()
    return true
end

-- Live single-setting apply (MCM_Setting_Saved / MCM_Setting_Reset payloads).
function MIR.ApplyMcmSetting(settingId, value, isReset)
    -- display-only views: any user tick/untick/reset is immediately overwritten
    -- (MCM's ReadOnly only hides add/remove; checkboxes stay clickable — review S1)
    if settingId == "mir_view_utility_excluded" or settingId == "mir_view_npcgear_excluded" then
        MIR.PublishCuratedLists()
        return
    end
    -- v1.2.0: the one list whose ticks mean something. Re-read authoritatively rather than
    -- trusting the payload, and sit before the LIST_IDS branch, which returns.
    if settingId == "mir_exclusions" then
        MIR.ReconcileExclusions(isReset == true)
        return
    end
    MIR.ConsoleOverrides[settingId] = nil -- explicit MCM action always wins
    local cat = SHARE_BY_ID[settingId]
    if cat then
        local v = coerce("int", value)
        if v ~= nil then
            MIR.Config.categoryWeights[cat] = v
            log("share " .. cat .. " = " .. v)
            MIR.PublishShares() -- keep the MIR Browser tab in step
        end
        return
    end
    local field = LIST_IDS[settingId]
    if field then
        local set, ok = readListSetting(settingId) -- authoritative re-read
        if ok then
            MIR.Config[field] = set
            MIR.RequestMcmRebuild(settingId)
        else
            log("list read FAILED for " .. settingId .. " - keeping current exclusions")
        end
        return
    end
    local m = SETTING_BY_ID[settingId]
    if not m then return end -- not ours / future setting
    local v = coerce(m.kind, value)
    if v == nil then return end
    applySetting(m, v)
    -- "mir_rw_" is SEVEN characters. sub(1, 8) yielded "mir_rw_l" and matched NOTHING, so
    -- the direction-aware clamp was unreachable on every live MCM change and a user who
    -- raised a minimum above its maximum got the window collapsed to the MAXIMUM tier by
    -- EffectiveRarityWindow's fallback - the opposite of the tier they just picked.
    if settingId:sub(1, 7) == "mir_rw_" or settingId == "mir_rarity_window_enabled" then
        MIR.NormalizeRarityWindow(settingId)
    end
    -- diff review M-2: the per-source sliders are clamped by `apply`; log the value in use
    local shown = v
    local ck, rk = settingId:match("^mir_chance_(.+)$"), settingId:match("^mir_rolls_(.+)$")
    if ck and MIR.Config.sourceChancePct[ck] ~= nil then shown = MIR.Config.sourceChancePct[ck] end
    if rk and MIR.Config.sourceRolls[rk] ~= nil then shown = MIR.Config.sourceRolls[rk] end
    log(settingId .. " = " .. tostring(shown) .. (m.rebuild and " (rebuild queued)" or ""))
    -- v1.1 (first plan review SF-3): the own sliders start at 25% x 1, not the General values
    local ownKey = settingId:match("^mir_own_(.+)$")
    if ownKey and v == true and MIR.EffectiveChanceRolls then
        local c, r = MIR.EffectiveChanceRolls(ownKey)
        log(("%s now use their own chance and rolls: %d%% x %d (the own sliders start at 25%% x 1,"
            .. " not your General values)"):format(MIR.SourceNames[ownKey] or ownKey, c, r))
    end
    if m.rebuild then MIR.RequestMcmRebuild(settingId)
    else
        MIR.PublishShares() -- v1.0: draw-time toggles change the panel's status too
        if MIR.ResetOnceLogged then MIR.ResetOnceLogged() end -- diff review M-1
    end
    if settingId == "mir_exclude_utility_mods" then MIR.PublishCuratedLists() end
end

-- First subscription attempt at file load (harmless if MCM's global/events
-- aren't up yet — SyncFromMCM retries via ensureSubscribed).
ensureSubscribed()

-- NOTE (review S1): the initial "session" sync is invoked by Main.lua's
-- SessionLoaded handler, immediately BEFORE its catalog build — a structural
-- ordering guarantee instead of relying on subscriber registration order.

Ext.RegisterConsoleCommand("mir_mcm_sync", function()
    local ok, err = pcall(function()
        if MIR.SyncFromMCM("console") then MIR.RequestMcmRebuild("console") end
    end)
    if not ok then log("mir_mcm_sync ERROR: " .. tostring(err)) end
    if MIR.FlushLog then MIR.FlushLog() end
end)

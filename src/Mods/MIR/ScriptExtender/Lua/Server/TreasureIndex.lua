-- MIR treasure-placement index (plan §5.1 #13, reworked 2026-08-24).
--
-- PURPOSE: detect items a mod ALREADY places somewhere findable, so MIR never
-- spawns a duplicate of an authored drop.
--
-- SCOPE RULE (the author, 2026-08-24 — verbatim): "If the mod places the items with a
-- merchant, in the camp chest, or in the tutorial chest, that does not count
-- from our exclusion perspective. In other words -- we want to exclude (on the
-- player's option) items that are placed with a specific NPC or in a specific
-- position or chest in the game world."
--
-- Therefore this index is PROVENANCE-AWARE. It does not ask "does this item
-- appear in some treasure table"; it asks "is this item placed somewhere the
-- player FINDS it". The distinction is made by WHAT REFERENCES the table:
--
--   character .TradeTreasures  -> merchant stock      -> NOT a placement (buying
--                                                        is not finding)
--   character .Treasures       -> that NPC's own loot -> PLACEMENT ("placed with
--                                                        a specific NPC")
--   item/container .InventoryList -> a world container -> PLACEMENT, UNLESS the
--       container is camp/tutorial/traveller storage (CONVENIENCE_PATTERNS below)
--       -> player-convenience storage, NOT an authored placement.
--   a table hung off MANY templates -> generic class loot, NOT "a specific NPC".
--
-- OPEN QUESTION the first in-game run must answer: MIR's own Phase-0 probe saw
-- InventoryList=nil on all 39 root templates it sampled, so world-container
-- detection may yield nothing. !mir_tables reports .InventoryList template counts
-- explicitly; if that number is 0, only the NPC half of the rule is live.
--
-- This is why the ROOT-TEMPLATE WALK is now the primary (and only) enumeration
-- path: it is the only one that knows who references a table. Enumerating the
-- stats manager's table list — the previous approach — yields names with no
-- provenance at all, which is precisely what made the old version fence a mod's
-- entire catalogue when the mod shipped a tutorial-chest table.
--
-- API FACTS (verified 2026-08-21, see _research/treasure_table_research_2026-08-21.md):
--   * Ext.Template.GetAllRootTemplates() -> map of root templates.
--   * Character templates carry .Treasures / .TradeTreasures; item templates
--     carry .InventoryList. Field names confirmed in the SE v32 binary and in
--     VolitionCabinet's shipped reader.
--   * Ext.Stats.TreasureTable.GetLegacy(id) / Ext.Stats.TreasureCategory.GetLegacy(id).
--     Legacy shape: TreasureTable.SubTables[].Categories[], each category edge
--     carrying EITHER .TreasureTable (nested table NAME) or .TreasureCategory
--     (category NAME); TreasureCategory.Items[] each have .Name.
--   * Items[].Name is the ITEM STAT NAME (BagsBagsBags proof case). The template
--     name is probed as a secondary key because some content names them alike.
--   * "Empty" is the engine's no-treasure sentinel.
-- NOTE: that research doc is SUPERSEDED on two points (goal-log 2026-08-21):
-- item refs are STAT names (not root-template names), and
-- Ext.Stats.GetStats("TreasureTable") does work (C++ FetchTreasureTableEntries).
-- Vanilla name facts (2026-08-24): the camp chest is CONT_PlayerCampChest_A..D;
-- NO vanilla template contains "Tutorial" or "TUT_Chest" (the Nautiloid chest is
-- most likely the generic CONT_GEN_Chest_Travel_A family).
-- Everything below is pcall'd and FAILS OPEN: no names -> nothing is fenced.
MIR = MIR or {}

local function log(m)
    if MIR.Log then MIR.Log("[tt] " .. tostring(m))
    else Ext.Utils.Print("[MIR][tt] " .. tostring(m)) end
end

-- Budgets (review B2): pass 1 now walks EVERY root template, so it gets its own
-- slice and cannot starve pass 2. A trip still yields PARTIAL = fence inert, but
-- a partial index is now RETRYABLE via !mir_tables instead of latching for the
-- whole session.
local PASS1_MS = 5000
local BUDGET_MS = 9000
local MAX_DEPTH = 24
-- Tables referenced by more than this many distinct templates are GENERIC
-- distribution (vanilla attaches e.g. bandit loot to whole classes of NPC), not
-- "placed with a specific NPC" — review S2.
local GENERIC_REF_LIMIT = 5

local function newStats()
    return { templates = 0, rootTables = 0, npcTables = 0, containerTables = 0,
             merchantTables = 0, convenienceTables = 0, genericTables = 0,
             tplWithTreasures = 0, tplWithTradeTreasures = 0, tplWithInventoryList = 0,
             tablesResolved = 0, categories = 0, itemRefs = 0, distinctItems = 0,
             missingTables = 0, missingCategories = 0, cycles = 0, depthCapped = 0,
             -- v1.2.0
             listedTables = 0, listedKeptFromGeneric = 0, revisits = 0,
             aborted = false }
end

MIR.TreasureIndex = {
    built = false,
    names = {},          -- [itemName] = { table = <table name>, via = <template name>, kind = "npc"|"container" }
    stats = newStats(),
    source = "none",
    partial = false,
    ms = 0,
    note = nil,
}

local function tryGet(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function deprefix(n, p)
    if type(n) == "string" and #n > 2 and n:sub(1, 2) == p then return n:sub(3) end
    return nil
end

-- Player-convenience storage: camp chest, tutorial chest, traveller's chest.
-- Deliberately its OWN list rather than borrowing Config.excludePatterns (review
-- S1): those two lists answer different questions ("never inject here" vs "this
-- is not an authored placement") and must be free to diverge. Matched
-- case-insensitively and kept deliberately WIDE, because a false negative here
-- re-creates the exact catastrophe this rewrite exists to prevent (a mod that
-- ships a tutorial chest having its whole catalogue fenced), while a false
-- positive merely leaves one more item in the pool.
local CONVENIENCE_PATTERNS = {
    "campchest", "chest_camp", "cont_camp", "tutorial", "tut_chest", "tut_",
    "travellerschest", "travelerschest", "traveller", "traveler", "storage",
}
local function isConvenienceName(name)
    if type(name) ~= "string" or name == "" then return false end
    local low = name:lower()
    for _, p in ipairs(CONVENIENCE_PATTERNS) do
        if low:find(p, 1, true) then return true end
    end
    return false
end

-- v1.2.0: the container half of MIR's own exclusion list. A mod's own container is DELIVERY
-- unless its name is on that list, and the user can switch any row of the list off in MCM -
-- which is honoured in MIR.PlacementFences, at fence time, NOT here. Whole-name match,
-- case-insensitive, never a substring - see the CONVENIENCE_PATTERNS note above for what
-- substring matching cost us in v1.1.2. Nil-safe: no list -> no listed containers.
local function isListedContainer(name)
    if type(name) ~= "string" or name == "" then return false end
    local l = MIR.PlacedContainers
    l = l and l.byLowerName
    return (l ~= nil and l[name:lower()] ~= nil)
end

-- ---------------- pass 1: which tables are PLACEMENTS, and via what ----------------
-- Returns roots = { [tableName] = { via = <template name>, kind = "npc"|"container" } }
-- plus the merchant/convenience tables recorded only for the report.
local function getField(o, k) return o[k] end

-- A treasure-table reference arrives either as a plain string or as a node
-- carrying .Object (the serialized game-data shape is
-- <node id="InventoryItem"><attribute id="Object" value="<table>"/></node>;
-- VolitionCabinet assumes SE flattens it to a string, which is UNVERIFIED —
-- so accept both rather than silently extracting nothing).
local function asTableName(v)
    if type(v) == "string" then return v end
    if type(v) == "table" or type(v) == "userdata" then
        local o = nil
        pcall(function() o = v.Object end)
        if type(o) == "string" then return o end
        pcall(function() o = v.Name end)
        if type(o) == "string" then return o end
    end
    return nil
end

local function collectPlacementTables(deadline, stats)
    local roots, skipped, refs = {}, {}, {}
    -- which entries of the shipped container list actually matched a template this session;
    -- a list entry that matches nothing is a silent no-op otherwise (plan review S5)
    local listHits = {}

    local templates = tryGet(function() return Ext.Template.GetAllRootTemplates() end)
    if templates == nil then return roots, skipped, false end

    local shapeLogged = false
    local timedOut = false
    local i = 0
    local okWalk = pcall(function()
        for _, t in pairs(templates) do
            i = i + 1
            -- sample the clock rather than calling it per template (review B2)
            if (i % 512) == 0 and Ext.Utils.MonotonicTime() > deadline then
                timedOut = true break
            end
            stats.templates = stats.templates + 1

            local okN, tname = pcall(getField, t, "Name")
            tname = (okN and type(tname) == "string") and tname or ""
            -- branch on TemplateType so we do not probe fields the type cannot
            -- have (review B2: that was ~2 thrown errors per template)
            local okT, ttype = pcall(getField, t, "TemplateType")
            ttype = (okT and type(ttype) == "string") and ttype:lower() or ""

            local function note(raw, kind, isPlacement)
                local tbl = asTableName(raw)
                if type(tbl) ~= "string" or tbl == "" or tbl == "Empty" then return end
                refs[tbl] = (refs[tbl] or 0) + 1
                if isPlacement then
                    local r = roots[tbl]
                    if not r then r = { via = tname, kind = kind } roots[tbl] = r end
                    -- v1.2.0 (plan review B1/B3): the first writer still supplies the names the
                    -- REPORT prints, but these two flags are ORed over EVERY referencing
                    -- template, so what the fence does can never depend on pairs() order - which
                    -- changes whenever a mod is added or removed.
                    if kind == "npc" then r.npc = true end
                    if kind == "container" and isListedContainer(tname) then
                        r.listed = true
                        -- v1.2.0: WHICH listed container, not just that one matched - the user
                        -- can switch an individual container rule off in MCM. Merged over every
                        -- referencing template, lower-cased to match the rule keys, so the set
                        -- cannot depend on pairs() order.
                        r.listedContainers = r.listedContainers or {}
                        r.listedContainers[tname:lower()] = true
                        -- diff review S5: `via` is the FIRST referencing template, which for a
                        -- shared table (Clothes_Rich_Random_Supply is referenced by many
                        -- wardrobes) is usually NOT the one on the list. Keep the listed name
                        -- separately so a why=container-list row names a container the user can
                        -- actually find in !mir_placed lists.
                        r.listedVia = r.listedVia or tname
                        listHits[tname:lower()] = true
                    end
                    -- a placement record beats a non-placement one for the same table; without
                    -- this the report can list a COUNTED table under TABLES DELIBERATELY
                    -- IGNORED (plan review M3)
                    if skipped[tbl] then skipped[tbl] = nil end
                elseif not roots[tbl] and not skipped[tbl] then
                    skipped[tbl] = { via = tname, kind = kind }
                end
            end

            if ttype ~= "item" then -- character (or unknown: probe both, cheaply)
                local okTr, trade = pcall(getField, t, "TradeTreasures")
                if okTr and trade ~= nil then
                    stats.tplWithTradeTreasures = stats.tplWithTradeTreasures + 1
                    pcall(function()
                        for _, n in pairs(trade) do note(n, "merchant", false) end
                    end)
                end
                local okTs, treas = pcall(getField, t, "Treasures")
                if okTs and treas ~= nil then
                    stats.tplWithTreasures = stats.tplWithTreasures + 1
                    pcall(function()
                        for _, n in pairs(treas) do
                            note(n, isConvenienceName(tname) and "convenience" or "npc",
                                 not isConvenienceName(tname))
                        end
                    end)
                end
            end
            if ttype ~= "character" then
                local okI, inv = pcall(getField, t, "InventoryList")
                if okI and inv ~= nil then
                    stats.tplWithInventoryList = stats.tplWithInventoryList + 1
                    -- one-shot shape log (review B1): MIR's own Phase-0 probe saw
                    -- InventoryList=nil on all 39 templates it sampled, so whether
                    -- this path yields anything at all is an OPEN QUESTION that the
                    -- first in-game run must answer.
                    if not shapeLogged then
                        shapeLogged = true
                        pcall(function()
                            local first = nil
                            for _, v in pairs(inv) do first = v break end
                            log(("InventoryList shape on '%s': type=%s first=%s (%s)"):format(
                                tname, type(inv), tostring(first), type(first)))
                        end)
                    end
                    -- diff review minor: the shipped list wins over the convenience
                    -- patterns. Without this a listed container whose name happens to contain
                    -- "storage", "tut_" or "traveller" would be classified convenience, never
                    -- become a placement, and the list entry would be a silent no-op.
                    local convenience = isConvenienceName(tname) and not isListedContainer(tname)
                    pcall(function()
                        for _, n in pairs(inv) do
                            note(n, convenience and "convenience" or "container", not convenience)
                        end
                    end)
                end
            end
        end
    end)
    if not okWalk then
        -- an abort truncates the placement set; the fence must not pretend the
        -- scan was complete (review S5)
        stats.aborted = true
        timedOut = true
    end

    -- Generic distribution: a table hung off many different templates is not
    -- "a specific NPC" (review S2). Demote those.
    for tbl, o in pairs(roots) do
        if (refs[tbl] or 0) > GENERIC_REF_LIMIT then
            -- v1.2.0 (plan review S5): a table reached through a container the user LISTED is
            -- never demoted. Demoting it would drop the one fence they asked for, silently.
            if o.listed then
                stats.listedKeptFromGeneric = stats.listedKeptFromGeneric + 1
            else
                roots[tbl] = nil
                skipped[tbl] = { via = o.via, kind = "generic" }
                stats.genericTables = stats.genericTables + 1
            end
        end
    end
    for tbl, o in pairs(skipped) do
        if o.kind == "merchant" then stats.merchantTables = stats.merchantTables + 1
        elseif o.kind == "convenience" then stats.convenienceTables = stats.convenienceTables + 1 end
    end
    for _, o in pairs(roots) do
        if o.kind == "npc" then stats.npcTables = stats.npcTables + 1
        else stats.containerTables = stats.containerTables + 1 end
    end
    return roots, skipped, timedOut, listHits
end

-- ---------------- pass 2: expand the placement tables into item names ----------------
-- v1.2.0 latch helpers. `seen[key]` is the set of listed-container names already expanded for
-- that table or category; an origin is only worth re-walking when it carries one that is new.
local function missingContainers(origin, seen, key)
    local want = origin.listedContainers
    if want == nil then return false end
    local have = seen[key]
    if have == nil then return true end
    for cname in pairs(want) do
        if not have[cname] then return true end
    end
    return false
end

local function markContainers(origin, seen, key)
    local want = origin.listedContainers
    if want == nil then return end
    local have = seen[key]
    if have == nil then have = {} seen[key] = have end
    for cname in pairs(want) do have[cname] = true end
end

local resolveTable, expandCategory

expandCategory = function(catName, origin, ctx)
    if ctx.timedOut then return end
    -- v1.2.0: the plain latch still stops the work being repeated, but a category reached a
    -- second time carrying a flag it has not been expanded with yet IS re-expanded, so the
    -- flags below are a true OR over every route to the item. Monotone, so at most three
    -- visits (plain, +npc, +listed).
    local needNpc = (origin.npc == true) and not ctx.doneCatNpc[catName]
    -- v1.2.0: the latch is per CONTAINER SET, not a single boolean. A plain boolean meant a
    -- category first reached through container W1 was never re-expanded for W2, so the item's
    -- container set held whichever one pairs() happened to reach first - the same order
    -- dependence an earlier review removed from the fence itself. Monotone: a re-visit must
    -- add a name it has not applied yet, so at most (2 + number of listed containers) visits
    -- per category - three listed containers today.
    local needListed = missingContainers(origin, ctx.doneCatContainers, catName)
    if ctx.doneCat[catName] and not needNpc and not needListed then return end
    if ctx.doneCat[catName] then ctx.stats.revisits = ctx.stats.revisits + 1 end
    ctx.doneCat[catName] = true
    if origin.npc == true then ctx.doneCatNpc[catName] = true end
    markContainers(origin, ctx.doneCatContainers, catName)
    local tc = tryGet(function() return Ext.Stats.TreasureCategory.GetLegacy(catName) end)
    if type(tc) ~= "table" then
        ctx.stats.missingCategories = ctx.stats.missingCategories + 1
        return
    end
    ctx.stats.categories = ctx.stats.categories + 1
    pcall(function()
        for _, item in ipairs(tc.Items or {}) do
            local n = item and item.Name
            if type(n) == "string" and n ~= "" then
                ctx.stats.itemRefs = ctx.stats.itemRefs + 1
                if ctx.names[n] == nil then
                    ctx.names[n] = origin
                    ctx.stats.distinctItems = ctx.stats.distinctItems + 1
                end
                local bare = deprefix(n, "I_")
                if bare and ctx.names[bare] == nil then ctx.names[bare] = origin end
                -- v1.2.0: the fence reads these, NOT ctx.names. Side maps rather than fields on
                -- `origin`, because one origin record is shared by reference across every item
                -- of a root table - writing per-item state onto it would corrupt the rest.
                if origin.npc == true then
                    ctx.fenceNpc[n] = true
                    if bare then ctx.fenceNpc[bare] = true end
                end
                if origin.listed == true then
                    -- v1.2.0: merge, never overwrite. One item can be reached through several
                    -- listed containers, and the fence must hold while ANY of them is still on.
                    for cname in pairs(origin.listedContainers or {}) do
                        local s = ctx.fenceContainers[n]
                        if not s then s = {} ctx.fenceContainers[n] = s end
                        s[cname] = true
                        if bare then
                            local b = ctx.fenceContainers[bare]
                            if not b then b = {} ctx.fenceContainers[bare] = b end
                            b[cname] = true
                        end
                    end
                end
            end
        end
    end)
end

resolveTable = function(name, origin, ctx)
    -- v1.2.0: same monotone re-visit rule as expandCategory, so a nested table shared by a
    -- listed and an unlisted container does not inherit only the first visitor's flags.
    local needNpc = (origin.npc == true) and not ctx.doneNpc[name]
    local needListed = missingContainers(origin, ctx.doneContainers, name)
    if ctx.done[name] and not needNpc and not needListed then return end
    if ctx.done[name] then ctx.stats.revisits = ctx.stats.revisits + 1 end
    if ctx.active[name] then ctx.stats.cycles = ctx.stats.cycles + 1 return end
    if ctx.depth >= MAX_DEPTH then ctx.stats.depthCapped = ctx.stats.depthCapped + 1 return end
    if Ext.Utils.MonotonicTime() > ctx.deadline then ctx.timedOut = true return end

    -- diff review S4: latch the flags BEFORE the lookup, as expandCategory does. Latching
    -- after it meant a name that does not resolve was re-probed once per flag combination,
    -- re-counting stats.missingTables up to three times for the same miss - and the
    -- T_-deprefix probes generate most of those misses.
    if origin.npc == true then ctx.doneNpc[name] = true end
    markContainers(origin, ctx.doneContainers, name)

    local tt = tryGet(function() return Ext.Stats.TreasureTable.GetLegacy(name) end)
    if type(tt) ~= "table" then
        ctx.stats.missingTables = ctx.stats.missingTables + 1
        ctx.done[name] = true
        return
    end
    ctx.stats.tablesResolved = ctx.stats.tablesResolved + 1
    ctx.active[name] = true
    ctx.depth = ctx.depth + 1

    pcall(function()
        for _, sub in ipairs(tt.SubTables or {}) do
            for _, cat in ipairs(sub.Categories or {}) do
                local nested = asTableName(cat and cat.TreasureTable)
                if type(nested) == "string" and nested ~= "" and nested ~= "Empty" then
                    -- a nested table inherits the provenance of whoever referenced it
                    resolveTable(nested, origin, ctx)
                    local bare = deprefix(nested, "T_")
                    if bare then resolveTable(bare, origin, ctx) end
                end
                local catName = cat and cat.TreasureCategory
                if type(catName) == "string" and catName ~= "" then
                    expandCategory(catName, origin, ctx)
                end
            end
        end
    end)

    ctx.depth = ctx.depth - 1
    ctx.active[name] = nil
    if not ctx.timedOut then ctx.done[name] = true end
end

-- ---------------- build ----------------
function MIR.BuildTreasureIndex(reason)
    local t0 = Ext.Utils.MonotonicTime()
    local stats = newStats()

    local roots, skipped, timedOut1, listHits = collectPlacementTables(t0 + PASS1_MS, stats)

    local ctx = { names = {}, done = {}, doneCat = {}, active = {}, depth = 0,
                  -- v1.2.0: fenceNpc and fenceContainers are what MIR.PlacementFences reads
                  -- (together with the user's own on/off state for each rule).
                  -- The doneNpc / doneContainers / doneCat* maps make the propagation
                  -- order-independent without re-walking everything. There is deliberately no
                  -- "listed" boolean any more: "is this item fenced by a container" is exactly
                  -- "does it have a container still switched on", and a second map would be one
                  -- more thing to keep in step.
                  fenceNpc = {},
                  -- [itemName] = { [lower container name] = true }
                  fenceContainers = {},
                  doneNpc = {}, doneCatNpc = {},
                  doneContainers = {}, doneCatContainers = {},
                  deadline = t0 + BUDGET_MS, timedOut = timedOut1, stats = stats }

    local nRoots = 0
    for tableName, origin in pairs(roots) do
        nRoots = nRoots + 1
        if origin.listed then stats.listedTables = stats.listedTables + 1 end
        if not ctx.timedOut then
            local o = { table = tableName, via = origin.via, kind = origin.kind,
                        npc = origin.npc, listed = origin.listed,
                        listedVia = origin.listedVia,
                        listedContainers = origin.listedContainers }
            resolveTable(tableName, o, ctx)
            local bare = deprefix(tableName, "T_")
            if bare then resolveTable(bare, o, ctx) end
        end
    end
    stats.rootTables = nRoots

    MIR.TreasureIndex = {
        built = true,
        names = ctx.names,
        -- v1.2.0: the fence's own maps. names[] stays what it always was - one report-only
        -- record per item - and is NOT used to decide anything.
        fenceNpc = ctx.fenceNpc,
        fenceContainers = ctx.fenceContainers,
        listHits = listHits or {},
        skipped = skipped,
        stats = stats,
        source = (nRoots > 0) and "rootTemplates" or "none",
        partial = ctx.timedOut and true or false,
        ms = math.floor(Ext.Utils.MonotonicTime() - t0),
        note = (nRoots == 0) and "no placement tables found (fence inert)" or nil,
    }
    -- pcall'd: a formatting slip here must NEVER destroy a good index by
    -- throwing into EnsureTreasureIndex's handler (review S4)
    pcall(function()
        local idx = MIR.TreasureIndex
        log(("index built in %d ms via %s%s: %d templates (Treasures=%d TradeTreasures=%d InventoryList=%d) -> %d placement table(s) [npc=%d container=%d] ; IGNORED: merchant=%d camp/tutorial=%d generic=%d ; %d resolved, %d distinct item name(s) (%s)")
            :format(idx.ms, idx.source,
                    idx.partial and " (PARTIAL - fence DISABLED this session; rerun !mir_tables)" or "",
                    stats.templates, stats.tplWithTreasures, stats.tplWithTradeTreasures,
                    stats.tplWithInventoryList, nRoots, stats.npcTables, stats.containerTables,
                    stats.merchantTables, stats.convenienceTables, stats.genericTables,
                    stats.tablesResolved, stats.distinctItems, tostring(reason)))
    end)
    return MIR.TreasureIndex
end

-- force=true rebuilds even a built index; used by !mir_tables so a PARTIAL or
-- errored scan is retryable instead of latched for the session (review B2).
function MIR.EnsureTreasureIndex(reason, force)
    if MIR.TreasureIndex.built and not force then return MIR.TreasureIndex end
    local ok, err = pcall(function() MIR.BuildTreasureIndex(reason) end)
    if not ok then
        MIR.TreasureIndex = { built = true, names = {}, skipped = {}, stats = newStats(),
                              source = "error", partial = false, ms = 0, note = tostring(err) }
        log("index build ERROR (fence inert this session): " .. tostring(err))
    end
    return MIR.TreasureIndex
end

-- The fence predicate. Probes the STAT name first (TreasureCategory.Items[].Name
-- is a stat name) and the template name second. A PARTIAL index makes the fence
-- inert for the session: fencing an arbitrary, load-order-dependent prefix would
-- be non-deterministic and unreproducible.
function MIR.HasTreasureDistribution(statName, templateName)
    local idx = MIR.TreasureIndex
    if not idx.built or idx.partial then return false end
    local n = idx.names
    if type(statName) == "string" and statName ~= ""
       and (n[statName] ~= nil or n["I_" .. statName] ~= nil) then return true end
    if type(templateName) == "string" and templateName ~= ""
       and (n[templateName] ~= nil or n["I_" .. templateName] ~= nil) then return true end
    return false
end

-- Where an item is placed (report only): returns table name, referencing template, kind.
function MIR.TreasureSourceOf(statName, templateName)
    local n = MIR.TreasureIndex.names
    local o = nil
    if type(statName) == "string" and statName ~= "" then
        o = n[statName] or n["I_" .. statName]
    end
    if o == nil and type(templateName) == "string" and templateName ~= "" then
        o = n[templateName] or n["I_" .. templateName]
    end
    if type(o) ~= "table" then return nil end
    return o.table, o.via, o.kind
end

-- v1.2.0 ---------------- does a placement still FENCE the item? ----------------
-- HasTreasureDistribution above keeps its old meaning - "some mod places this somewhere" -
-- because the browser's duplicate warning and !mir_placed_mods need exactly that, and it
-- stays true for an item this function frees. What is FENCED is now a narrower question:
--
--   * an NPC placement always fences (a mod put this on a specific character);
--   * a container placement fences only when the shipped mod list names the item's mod, or
--     the shipped container list names a container it is reached through;
--   * every other mod container is DELIVERY, not an authored world placement (the author,
--     2026-10-18), so it does not fence.
--
-- Returns a REASON string ("npc" / "mod-list" / "container-list") or nil, so the report and
-- the browser can say why. Reads the index's own flag maps, which were ORed over every
-- referencing template during the scan - never pairs() order, and never TreasureSourceOf,
-- which is a report-only single record (plan review B1/B2/B3).
-- Fails OPEN on anything missing: no index, a PARTIAL index or a missing list means nothing
-- is fenced, which is the same contract HasTreasureDistribution has carried since v0.7.
local EMPTY_SET = {}
local function containerSet(idx, statName, templateName)
    local map = idx and idx.fenceContainers
    if type(map) ~= "table" then return EMPTY_SET end
    local out, any = {}, false
    local function takeOne(key)
        local s = map[key]
        if type(s) == "table" then
            for cname in pairs(s) do out[cname] = true any = true end
        end
    end
    local function take(k)
        if type(k) ~= "string" or k == "" then return end
        takeOne(k)
        takeOne("I_" .. k)
    end
    take(statName)
    take(templateName)
    return any and out or EMPTY_SET
end

function MIR.PlacementFences(statName, templateName, modKey)
    local idx = MIR.TreasureIndex
    if not idx or not idx.built or idx.partial then return nil end
    if not MIR.HasTreasureDistribution then return nil end
    local okPlaced, placed = pcall(MIR.HasTreasureDistribution, statName, templateName)
    if not okPlaced or not placed then return nil end

    local function flagged(map, n)
        if type(map) ~= "table" or type(n) ~= "string" or n == "" then return false end
        return map[n] == true or map["I_" .. n] == true
    end

    -- NPC first: it is the strongest statement about an item, so it is the reason worth
    -- reporting when both are true.
    if flagged(idx.fenceNpc, statName) or flagged(idx.fenceNpc, templateName) then
        return "npc"
    end
    -- v1.2.0: a shipped default only fences while the user has it switched on. The test is
    -- MIR.DefaultExclusionOn, which also covers the master tick above the list in MCM, and
    -- which is nil-safe in both directions.
    local on = MIR.DefaultExclusionOn or function() return true end
    local ml = MIR.PlacedContainerMods
    ml = ml and ml.byUuid
    if ml and type(modKey) == "string" and modKey ~= "" and ml[modKey]
       and on("mod:" .. modKey) then
        return "mod-list"
    end
    -- Fence while ANY contributing listed container is still on. The sets are merged over every
    -- referencing template during the scan, so this answer does not depend on iteration order.
    for cname in pairs(containerSet(idx, statName, templateName)) do
        if on("container:" .. cname) then return "container-list" end
    end
    return nil
end

-- The union of every listed container that reached this item, under its stat name, its
-- `I_`-prefixed alias and its template name. Union, not first-non-nil: the three keys can
-- legitimately carry different sets.
function MIR.PlacementContainerSet(statName, templateName)
    return containerSet(MIR.TreasureIndex, statName, templateName)
end

-- Which shipped list entries did nothing this session (plan review S5). A by-mod entry whose
-- UUID never appears, or a container name no template carries, is otherwise invisible.
function MIR.PlacementListReport()
    local lines = {}
    local mods = (MIR.PlacedContainerMods and MIR.PlacedContainerMods.byUuid) or {}
    local conts = (MIR.PlacedContainers and MIR.PlacedContainers.byName) or {}
    local hits = (MIR.TreasureIndex and MIR.TreasureIndex.listHits) or {}
    local nMods, missMods = 0, {}
    for uuid in pairs(mods) do
        nMods = nMods + 1
        local seen = false
        pcall(function()
            for _, e in pairs(MIR.Catalog and MIR.Catalog.byTemplate or {}) do
                if e.mod == uuid then seen = true break end
            end
            if not seen then
                for _, e in pairs(MIR.Catalog and MIR.Catalog.tableExcluded or {}) do
                    if e.mod == uuid then seen = true break end
                end
            end
        end)
        if not seen then missMods[#missMods + 1] = uuid end
    end
    local missConts = {}
    for _, n in ipairs(conts) do
        if not hits[tostring(n):lower()] then missConts[#missConts + 1] = n end
    end
    lines[#lines + 1] = ("shipped mod list:        %d entr(ies), %d matched no item in this load order")
        :format(nMods, #missMods)
    for _, u in ipairs(missMods) do lines[#lines + 1] = "    no items: " .. tostring(u) end
    lines[#lines + 1] = ("shipped container list:  %d entr(ies), %d matched no placed container")
        :format(#conts, #missConts)
    for _, n in ipairs(missConts) do lines[#lines + 1] = "    no match: " .. tostring(n) end
    return lines
end

-- ---------------- !mir_tables report ----------------
function MIR.TreasureReport()
    local idx = MIR.TreasureIndex
    local s = idx.stats or newStats()
    local lines = {
        "MIR placement-detection report",
        "",
        "SCOPE RULE (v1.2.0): an item is HELD BACK only when",
        "  * a mod put it on a specific NPC (that character's own loot), or",
        "  * its mod, or the container it comes in, is on MIR's own exclusion list - which you",
        "    can see and change in MCM, on the Exclusions and overrides tab under \"Mods MIR does not",
        "    use\": untick a row there and MIR starts using that mod. !mir_placed lists prints",
        "    the same list with its current state.",
        "Every OTHER container a mod ships - its backpacks, bags, boxes and chests - counts as",
        "DELIVERY, not an authored world placement, so those items stay in MIR's pool. Up to",
        "v1.1.2 they were all held back, which on a big load order was thousands of items that",
        "a mod merely HANDED you. Merchant stock still does not count (buying is not finding).",
        "MIR cannot see where a container actually sits: vanilla assigns most container loot on",
        "level INSTANCES, which the root-template walk below cannot read - hence the lists.",
        "",
        "EXCLUDED here means MIR will not SPAWN a copy. MIR never removes, replaces or",
        "suppresses anything the game or another mod gives you - the mod still places its own.",
        "",
        ("source=%s partial=%s scan=%d ms toggle=%s"):format(
            tostring(idx.source), tostring(idx.partial), idx.ms or 0,
            tostring(MIR.Config and MIR.Config.excludeTreasureTableItems)),
        ("root templates walked:        %d"):format(s.templates),
        ("  with .Treasures:            %d"):format(s.tplWithTreasures),
        ("  with .TradeTreasures:       %d"):format(s.tplWithTradeTreasures),
        ("  with .InventoryList:        %d   <- if 0, world-container detection is not working"):format(s.tplWithInventoryList),
        ("placement tables (COUNTED):   %d   [npc=%d container=%d]"):format(s.rootTables, s.npcTables, s.containerTables),
        ("merchant tables (ignored):    %d"):format(s.merchantTables),
        ("camp/tutorial (ignored):      %d"):format(s.convenienceTables),
        ("generic/many-NPC (ignored):   %d"):format(s.genericTables),
        ("on the container part of the list: %d   (kept from generic demotion: %d, re-visits: %d)"):format(
            s.listedTables or 0, s.listedKeptFromGeneric or 0, s.revisits or 0),
        ("exclusion list: %d of %d rule(s) switched on%s"):format(
            (function()
                local k = 0
                for _, r in ipairs(MIR.DefaultExclusions or {}) do
                    if MIR.DefaultExclusionOn == nil or MIR.DefaultExclusionOn(r.key) then k = k + 1 end
                end
                return k
            end)(),
            #(MIR.DefaultExclusions or {}),
            (MIR.Config and MIR.Config.defaultExclusionsEnabled == false)
                and "  (the whole list is switched off in MCM)" or ""),
        ("scan aborted mid-walk:        %s"):format(tostring(s.aborted)),
        ("tables resolved:              %d"):format(s.tablesResolved),
        ("categories expanded:          %d"):format(s.categories),
        ("item references seen:         %d"):format(s.itemRefs),
        ("distinct item names indexed:  %d"):format(s.distinctItems),
        ("tables that would not resolve:%d   categories: %d   cycles: %d   depth-capped: %d"):format(
            s.missingTables, s.missingCategories, s.cycles, s.depthCapped),
        "",
    }
    if idx.note then lines[#lines + 1] = "NOTE: " .. tostring(idx.note) end

    -- v1.2.0: did the two shipped lists actually match anything?
    pcall(function()
        if MIR.PlacementListReport then
            lines[#lines + 1] = "MIR'S OWN EXCLUSION LIST (change it in MCM)"
            for _, l in ipairs(MIR.PlacementListReport()) do lines[#lines + 1] = l end
            lines[#lines + 1] = ""
        end
    end)

    -- which of MIR's own catalog items are fenced, and by what
    local fenced, n = {}, 0
    pcall(function()
        for _, e in pairs(MIR.Catalog and MIR.Catalog.tableExcluded or {}) do
            local tbl, via, kind = MIR.TreasureSourceOf(e.stat, e.tplName)
            n = n + 1
            -- diff review S5: for a container-list fence, name the LISTED container rather
            -- than the arbitrary first referencing template
            local shown = via
            if e.fencedBy == "container-list" and MIR.PlacementContainerSet then
                -- v1.2.0: name a container from the per-item set rather than from the
                -- report-only `names` record, which is first-writer-wins. Sorted, and
                -- preferring one that is still switched on, so the row is stable between runs.
                local names = {}
                for cname in pairs(MIR.PlacementContainerSet(e.stat, e.tplName) or {}) do
                    names[#names + 1] = cname
                end
                table.sort(names)
                local on = MIR.DefaultExclusionOn or function() return true end
                local pick = nil
                for _, cname in ipairs(names) do
                    if on("container:" .. cname) then pick = cname break end
                end
                pick = pick or names[1]
                if pick then
                    local pretty = MIR.PlacedContainers and MIR.PlacedContainers.byLowerName
                    shown = (pretty and pretty[pick]) or pick
                end
            end
            fenced[#fenced + 1] = ("%-44s %-10s <- %s [%s: %s] why=%s"):format(
                tostring(e.name or e.stat), tostring(e.category),
                tostring(tbl or "?"), tostring(kind or "?"), tostring(shown or "?"),
                tostring(e.fencedBy or "?"))
        end
    end)

    -- v1.2.0: and which placed items MIR now leaves in the pool, so a user can see what to
    -- add to an exclusion list of their own (!mir_exclude) if they disagree with a call.
    local freed, nFreed = {}, 0
    pcall(function()
        for _, e in pairs(MIR.Catalog and MIR.Catalog.byTemplate or {}) do
            -- diff review S3: `or e.forced` - a force-included item IS fenced in principle but
            -- is in the pool anyway, and without this it appeared in neither section of the
            -- report, which also made the "(force-included by you)" suffix unreachable.
            if e.placed and (not e.fenced or e.forced) then
                nFreed = nFreed + 1
                local tbl, via, kind = MIR.TreasureSourceOf(e.stat, e.tplName)
                freed[#freed + 1] = ("%-44s %-10s <- %s [%s: %s]%s"):format(
                    tostring(e.name or e.stat), tostring(e.category),
                    tostring(tbl or "?"), tostring(kind or "?"), tostring(via or "?"),
                    e.forced and "  (force-included by you)" or "")
            end
        end
    end)
    table.sort(freed)
    table.sort(fenced)
    local ign = {}
    pcall(function()
        for tbl, o in pairs(idx.skipped or {}) do
            ign[#ign + 1] = ("  %-46s %-12s via %s"):format(tbl, tostring(o.kind), tostring(o.via))
        end
    end)
    table.sort(ign)
    lines[#lines + 1] = ("TABLES DELIBERATELY IGNORED: %d"):format(#ign)
    for _, l in ipairs(ign) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("ITEMS CURRENTLY EXCLUDED FROM MIR'S SPAWN POOL: %d"):format(n)
    lines[#lines + 1] = "(name / category / treasure table <- [why: which NPC or container] why=which rule)"
    for _, l in ipairs(fenced) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    -- diff review S7: with the fence off nothing carries .placed, so both of these sections
    -- would read 0 and imply MIR is holding things back when it is holding back nothing.
    if not (MIR.Config and MIR.Config.excludeTreasureTableItems) then
        lines[#lines + 1] = "THE FILTER IS OFF: nothing is held back, and every item a mod places"
        lines[#lines + 1] = "is also in MIR's spawn pool, so duplicates are possible. Turn on"
        lines[#lines + 1] = "\"Exclude items their mod already places in the world\" in MCM to apply"
        lines[#lines + 1] = "the rule described above, then run !mir_tables again for the two lists."
        return lines
    end
    lines[#lines + 1] = ("ITEMS A MOD PLACES BUT MIR STILL SPAWNS: %d"):format(nFreed)
    lines[#lines + 1] = "(v1.2.0: their container is a mod's own delivery container, so it does not fence."
    lines[#lines + 1] = " You may therefore find two of one of these - the mod's copy and MIR's. Use"
    lines[#lines + 1] = " !mir_exclude <template> or the MIR Browser tab to put any of them back.)"
    for _, l in ipairs(freed) do lines[#lines + 1] = l end
    return lines
end

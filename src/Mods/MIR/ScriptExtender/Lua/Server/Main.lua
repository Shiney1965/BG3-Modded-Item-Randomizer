-- MIR injection core (Phase 2): loot hooks, roll pipeline, no-duplicate ledger.
-- Hooks and guards are exactly the Phase-0-verified set. Additive-only by design:
-- the ONLY inventory-mutating call in this mod is Osi.TemplateAddTo.
MIR = MIR or {}

local LOGFILE = "MIR_log.txt"
local buf, lastFlush = {}, 0
local function now() return Ext.Utils.MonotonicTime() end
-- seed the buffer from the existing file so sessions append instead of overwrite
do
    local ok, prev = pcall(Ext.IO.LoadFile, LOGFILE)
    if ok and prev and prev ~= "" then
        buf[1] = prev
        buf[2] = "===== NEW SESSION ====="
    end
end
local function flush()
    lastFlush = now()
    pcall(function() Ext.IO.SaveFile(LOGFILE, table.concat(buf, "\n")) end)
end
local function log(m)
    local line = "[" .. tostring(now()) .. "] " .. tostring(m)
    Ext.Utils.Print("[MIR] " .. line)
    buf[#buf + 1] = line
    if now() - lastFlush > 1000 then flush() end
end
MIR.Log = log
MIR.FlushLog = flush

local function guid36(s)
    s = tostring(s)
    if #s >= 36 then return s:sub(-36) end
    return s
end
local function namePart(s) -- "CONT_Chest_X_uuid" -> "CONT_Chest_X"
    s = tostring(s)
    if #s > 37 then return s:sub(1, #s - 37) end
    return s
end

-- ---------------- session / level state ----------------
local gameplayActive = false
local currentLevel = ""
local hydrated = false

-- ---------------- ledger ----------------
local function ledgerGet()
    local mv = Ext.Vars.GetModVariables(ModuleUUID)
    return mv, (mv and mv.SpawnedItems) or {}
end

local function ledgerAdd(tplId, holderGuid)
    local ok, err = pcall(function()
        local mv, t = ledgerGet()
        if not mv then error("mod variables unavailable") end
        t[tplId] = { holder = holderGuid, at = now() }
        mv.SpawnedItems = t  -- reassignment marks the mod variable dirty (persists on save)
        pcall(function() Ext.Vars.SyncModVariables() end)
    end)
    if not ok then log("LEDGER WRITE FAILED for " .. tostring(tplId) .. ": " .. tostring(err) .. " (item spawned but not recorded!)") end
end

local function hydrateLedger()
    if hydrated or not MIR.Catalog.built then return end
    local ok, t = pcall(function()
        local mv, tab = ledgerGet()
        if not mv then error("mod variables unavailable") end
        return tab
    end)
    if not ok then log("Ledger hydration FAILED (will retry next event): " .. tostring(t)) return end
    hydrated = true -- latch only after a successful read
    local n = 0
    for tplId in pairs(t) do
        MIR.RemoveFromPool(tplId)
        n = n + 1
    end
    log("Ledger hydrated: " .. n .. " previously spawned item(s) removed from the live pool")
end

-- v1.1: notices logged ONCE per session per loot source (delta review M-1/M-2), re-armed by
-- every rebuild because a rebuild means the settings changed.
local onceLogged = {}
local function logOnce(key, msg)
    if onceLogged[key] then return end
    onceLogged[key] = true
    log(msg)
end
-- diff review M-1: draw-time setting changes (own chance/rolls, wardrobe and ring boxes ...)
-- do not rebuild, so MCMSync and the console setters re-arm the notices explicitly.
function MIR.ResetOnceLogged() onceLogged = {} end

-- Shared rebuild path (console toggles + MCM live-apply, design §3.3).
function MIR.RebuildAndRehydrate(tag)
    if MIR.McmMissing then log("dormant (MCM not installed) - rebuild skipped") return end
    hydrated = false
    local cat = MIR.BuildCatalog()
    log("catalog rebuilt in " .. cat.builtMs .. " ms (" .. tostring(tag) .. "); eligible=" .. cat.stats.eligible
        .. " treasureTable=" .. tostring(cat.stats.skippedTreasureTable or 0)
        .. " (of the eligible, reserved for one loot source: " .. MIR.ScopedSummary(cat.stats) .. ")")
    onceLogged = {}
    hydrateLedger()
    if MIR.BrowserBumpGen then MIR.BrowserBumpGen() end
    if MIR.PublishShares then MIR.PublishShares() end
    flush()
end

-- ---------------- per-entity processed flags ----------------
-- v0.8 (review B4): the stamp records WHY a container was finished with, but this used to
-- test only for its PRESENCE. That made a GATE-SKIP permanent: every container passed over
-- while a toggle was off could never roll again, so the new wardrobe class would have been
-- invisible on any existing save. Only decisions that actually CONSUMED the container are
-- terminal. Anything unknown or empty is treated as terminal too - re-rolling a container
-- whose provenance we cannot establish risks a double spawn, so the safe default is 'done'.
-- v1.0: `bookshelf` added (plan review BL-2) - without it every bookshelf walked past while
-- the toggle was off would have been dead forever on that save, the v0.8 B4 bug again.
-- v1.1: `vase` (the new class - the same bug class again) and `zero` (a source whose chance
-- or rolls is 0: nothing was rolled, so nothing was consumed - plan review BL-1).
-- v1.1.1: `treasure` too - a SAFEGUARD only. The chest switch deliberately writes no stamp (plan
-- review SF-1), and no MIR version has ever written a `treasure` note (checked across every pak).
local RETRY_NOTES = { treasure = true, clutter = true, vase = true, wardrobe = true, bookshelf = true, dryrun = true, zero = true }
local function isProcessed(u)
    local done = false
    pcall(function()
        local e = Ext.Entity.Get(u)
        local v = e and e.Vars.MIR_Processed
        if not v then return end
        local note = tostring(v.note or "")
        if not RETRY_NOTES[note] then done = true end
    end)
    return done
end

local function markProcessed(u, note)
    pcall(function()
        local e = Ext.Entity.Get(u)
        if e then
            -- v1.1 (delta review M-2): a retryable stamp is rewritten on every re-open of the
            -- same container; skip the write and the sync when nothing would change.
            local cur = e.Vars.MIR_Processed
            if cur and RETRY_NOTES[note or ""] and tostring(cur.note or "") == note then return end
            e.Vars.MIR_Processed = { v = 1, note = note or "" }
            Ext.Vars.DirtyUserVariables(u, "MIR_Processed")
            Ext.Vars.SyncUserVariables()
        end
    end)
end

-- ---------------- container classification ----------------
local function matchesAny(name, patterns)
    for _, p in ipairs(patterns) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

-- Returns "excluded", "wardrobe", "bookshelf", "treasure", "vase" or "clutter" - tested in that order.
local function classifyContainer(rootTplComposite, instanceComposite)
    local rootName = namePart(rootTplComposite)
    local instName = namePart(instanceComposite)
    local cfg = MIR.Config
    if matchesAny(rootName, cfg.excludePatterns) or matchesAny(instName, cfg.excludePatterns) then
        return "excluded"
    end
    -- v0.8: wardrobes are their own class. Tested BEFORE treasure so a 'wardrobe chest'
    -- reads as a wardrobe, and AFTER excludePatterns so FUR_GEN_Wardrobe_Player_A (the
    -- player's camp wardrobe) is already gone.
    if matchesAny(rootName, cfg.wardrobePatterns) or matchesAny(instName, cfg.wardrobePatterns) then
        return "wardrobe"
    end
    -- v1.0: bookshelves, bookcases, book piles, scroll shelves and desks. Before treasure
    -- for the same reason as wardrobes; after wardrobes so a closet with books stays a closet.
    if matchesAny(rootName, cfg.bookshelfPatterns) or matchesAny(instName, cfg.bookshelfPatterns) then
        return "bookshelf"
    end
    if matchesAny(rootName, cfg.treasurePatterns) or matchesAny(instName, cfg.treasurePatterns) then
        return "treasure"
    end
    -- v1.1: vases, urns, jars and amphorae (Alan, 2026-09-10). AFTER treasure, so nothing that
    -- is a chest today changes class; everything still unmatched stays the catch-all clutter.
    if matchesAny(rootName, cfg.vasePatterns or {}) or matchesAny(instName, cfg.vasePatterns or {}) then
        return "vase"
    end
    return "clutter"

end

local function hasComponent(u, comp)
    local present = false
    pcall(function()
        local e = Ext.Entity.Get(u)
        if e and e[comp] ~= nil then present = true end
    end)
    return present
end

-- ---------------- rarity window ----------------
-- Effective window = MOST RESTRICTIVE of the level rule and the Act rule: highest min,
-- LOWEST max (Alan, 2026-08-30). Supersedes the original spec on the max side, because
-- under 'highest max' lowering a single maximum did nothing at all.
local rwClampWarned, rwNoBandWarned, rwNoLevelWarned = false, false, false
-- Returns minTier, maxTier, plus a table describing HOW it got there (for !mir_rarity).
function MIR.EffectiveRarityWindow()
    local cfg = MIR.Config.rarityWindow
    if not cfg.enabled then return 1, 5, { off = true } end

    -- review SF-7: a FAILED level read must mean 'no level rule', not 'treat as level 1',
    -- which silently applied the strictest band.
    local lvl = nil
    pcall(function() lvl = tonumber(Osi.GetLevel(Osi.GetHostCharacter())) end)
    local minL, maxL, band = 1, 5, nil
    if lvl then
        if lvl < 1 then lvl = 1 end
        for _, r in ipairs(cfg.levelRules) do
            if lvl >= r.minLevel and lvl <= r.maxLevel then
                minL, maxL, band = r.minTier, r.maxTier, r
                break
            end
        end
        if not band and not rwNoBandWarned then
            rwNoBandWarned = true
            log(("rarity window: character level %d matched NO level band - the level rule is"):format(lvl))
            log("        being ignored and only the Act rule applies. Widen the top band.")
        end
    elseif not rwNoLevelWarned then
        rwNoLevelWarned = true
        log("rarity window: could not read the host's level - ignoring the level rule this session.")
    end

    local act = MIR.CurrentAct or 1
    local ar = cfg.actRules[act] or { minTier = 1, maxTier = 5 }

    -- MOST RESTRICTIVE WINS (Alan 2026-08-30): highest min, LOWEST max.
    local mn = math.max(minL, ar.minTier)
    local mx = math.min(maxL, ar.maxTier)

    -- Defensive clamp at the single choke point every write path funnels into. Under an
    -- INTERSECTION the window really can come out empty (band 4-5 vs Act 1-2), which would
    -- silently stop all spawning; better to narrow to one tier and say so once.
    mn = math.max(1, math.min(5, mn))
    mx = math.max(1, math.min(5, mx))
    if mn > mx then
        if not rwClampWarned then
            rwClampWarned = true
            log(("rarity window: level rule %d-%d and Act %d rule %d-%d do not overlap.")
                :format(minL, maxL, act, ar.minTier, ar.maxTier))
            log(("        Clamping to %s only. Widen one of them."):format(tostring(MIR.TierName[mx])))
        end
        mn = mx
    end
    return mn, mx, { off = false, lvl = lvl, band = band, act = act, ar = ar,
                     levelMin = minL, levelMax = maxL }
end

local function effectiveRarityWindow()
    local mn, mx = MIR.EffectiveRarityWindow()
    return mn, mx
end


-- ---------------- roll pipeline ----------------
-- v0.8 category groups. Derived from the existing 15 categories - nothing new invented.
-- CONSUMABLE mirrors the Object branch in Catalog.lua, so the two cannot drift.
local CONSUMABLE_CATS  = { potion = true, arrow = true, alchemyIngredient = true }
-- v1.0: scrolls are consumable (repeatable, ledger-exempt) but NOT in the consumable group -
-- they have their own admission: bookshelves, and barrels / vases on "everything" (v1.1).
local SCROLL_CATS      = { scroll = true }
local COSMETIC_CATS    = { vanityClothing = true, vanityBoots = true, underwear = true }
-- worn armour only. Deliberately NOT weapon/shield/ring/amulet: those are not garments,
-- and a greatsword in a wardrobe is the behaviour being complained about.
local STATGARMENT_CATS = { torso = true, helmet = true, gloves = true, boots = true, cloak = true }

-- filter = { class = <string>, allowed = <set|nil>, allowCosmetics = <bool>,
--            allowConsumables = <bool>, allowScrolls = <bool>, nothing = <bool> }
-- allowed == nil means UNRESTRICTED. nothing == true means the class admits NOTHING at all
-- (bookshelves, wardrobes, barrels and vases with nothing ticked). Since v1.1 every
-- `allowed` table returned here is a fresh table; still treat them as READ-ONLY.
-- v1.1: every key of categoryWeights, as a FRESH set (a caller may not alias shared tables)
local function allCategories()
    local t = {}
    for c in pairs(MIR.Config.categoryWeights) do t[c] = true end
    return t
end

-- v1.1 (Alan, 2026-09-10): barrels & crates (`clutter`) and vases/urns/jars/amphorae (`vase`)
-- share ONE tick-what-you-want shape. prefix = the config prefix ("clutter" / "vase").
--   none ticked -> NOTHING (like bookshelves; there is no unrestricted fallback any more)
--   everything  -> every category; it admits consumables, scrolls and camp clothing for this
--                  source whatever the Pool tab says (Alan's Q5: "no gate on UI toggle")
--   otherwise   -> the ticked subset of rings / potions / arrows / alchemy ingredients
-- INVARIANTS (delta review SF-A - they keep Catalog.lua's admission and this draw gate
-- identical, so nothing is admitted that cannot be drawn): allowConsumables is true whenever
-- any consumable box or everything is ticked; allowScrolls is true exactly when everything is.
local function boxedSourceFilter(class, prefix)
    local cfg = MIR.Config
    if cfg[prefix .. "AllItems"] then
        return { class = class, allowed = allCategories(),
                 allowConsumables = true, allowScrolls = true, allowCosmetics = true }
    end
    local allowed, anyConsumable = {}, false
    if cfg[prefix .. "Rings"] then allowed.ring = true end
    for cat, box in pairs(MIR.ConsumableBox) do
        if cfg[prefix .. box] then allowed[cat] = true anyConsumable = true end
    end
    if next(allowed) == nil then
        return { class = class, allowed = {}, nothing = true, allowConsumables = false, allowScrolls = false }
    end
    return { class = class, allowed = allowed, allowConsumables = anyConsumable,
             allowScrolls = false, allowCosmetics = false }
end

function MIR.ContentFilterFor(class)
    local cfg = MIR.Config
    if class == "clutter" then return boxedSourceFilter(class, "clutter") end
    if class == "vase" then return boxedSourceFilter(class, "vase") end

    if class == "bookshelf" then
        -- v1.0 (and every boxed source since v1.1): both boxes off = NOTHING, not
        -- unrestricted (plan review BL-1): the defaults are scrolls ON / all-items OFF, so a
        -- user who unticks scrolls to STOP scrolls must not be handed greatswords instead.
        -- allowScrolls is what lets a bookshelf draw scrolls while includeScrolls is off.
        -- Set HERE and nowhere else - the wardrobe "all items" loop also puts `scroll` into
        -- its allowed set, and keying the gate on filter.allowed[cat] would leak them there
        -- (the identical trap review BL-2 fell into for consumables).
        local scrolls, all = cfg.bookshelfScrolls and true or false, cfg.bookshelfAllItems and true or false
        if not (scrolls or all) then
            return { class = class, allowed = {}, nothing = true, allowScrolls = false }
        end
        local allowed = {}
        if scrolls then allowed.scroll = true end
        if all then for c in pairs(cfg.categoryWeights) do allowed[c] = true end end
        return { class = class, allowed = allowed, allowScrolls = scrolls }
    end

    if class == "wardrobe" then
        -- v1.1 (Alan, 2026-09-10): "you check it if you want it". Nothing ticked = NOTHING (until
        -- v1.0.1 it meant unrestricted). "Everything" is a SUPERSET: every category, camp
        -- clothing included whatever the Pool tab says; consumables and scrolls on pool-wide
        -- terms, as in a chest (plan A2/A4).
        local cos, stat, all = cfg.wardrobeCosmetics, cfg.wardrobeStatGarments, cfg.wardrobeAllItems
        if all then return { class = class, allowed = allCategories(), allowCosmetics = true } end
        if not (cos or stat) then return { class = class, allowed = {}, nothing = true } end
        local allowed = {}
        if cos then for c in pairs(COSMETIC_CATS) do allowed[c] = true end end
        if stat then for c in pairs(STATGARMENT_CATS) do allowed[c] = true end end
        return { class = class, allowed = allowed, allowCosmetics = cos and true or false }
    end
    return { class = class } -- treasure / corpse: unrestricted, unchanged
end

-- ---------------- v1.0.1: per-ENTRY container scoping ----------------
-- Entries admitted ONLY because loot sources asked for them carry `scope`, the SET of those
-- sources (Catalog.lua; clutterOnly / bookshelfOnly until v1.1). It is load-bearing: such an entry is
-- drawable for that class and NOWHERE else. This is what lets clutter admit VANILLA
-- consumables locally: the per-category gates below cannot tell a vanilla potion from a
-- modded one (the v0.9 BL-2 / S-1 leak), but the entry can. filter == nil rejects every
-- scoped entry, which is the right meaning for "an unrestricted container".
local function entryAllowedFor(e, filter)
    -- v1.1: e.scope is a SET of loot sources (true keys only); nil = pool-wide
    if e.scope and not e.scope[(filter and filter.class) or ""] then return false end
    return true
end

-- v1.0.1 (Alan, 2026-09-03): "ingredients should not have a rarity filter if they are all
-- Common." Vanilla declares no rarity for any alchemy ingredient (38 of 38 in the extract),
-- so MIR files every one as Common and a window above Common silently removed them all -
-- which is exactly what he saw in Act 3. Exempt categories always draw from all five tiers.
-- Surfaced on the Rarity tab, the ingredient row of the MIR Browser and !mir_rarity.
-- v1.1.2: `extra` joins them - Objects declare no Rarity, so every allow-list item is
-- filed Common and a window above Common would silently remove the lot (the v1.0.1
-- ingredient bug, plan review SF-6).
local RARITY_EXEMPT_CATS = { alchemyIngredient = true, extra = true }
MIR.RarityExemptCats = RARITY_EXEMPT_CATS
local function tierRangeFor(cat, minTier, maxTier)
    if RARITY_EXEMPT_CATS[cat] then return 1, 5 end
    return minTier, maxTier
end

local function sliceHasAllowed(slice, filter)
    if not slice then return false end
    for _, e in ipairs(slice) do
        if entryAllowedFor(e, filter) then return true end
    end
    return false
end
local function catHasAllowedInRange(slices, lo, hi, filter)
    for t = lo, hi do
        if sliceHasAllowed(slices[MIR.TierName[t]], filter) then return true end
    end
    return false
end

-- v1.0: the per-category include veto (categoryIncluded) is GONE - see Config.lua. This
-- function now answers "may this category be DRAWN for this container?" from weights and
-- the pool/container gates only. It never looks at the pool contents; callers that need
-- "is there actually anything to draw" test the slices themselves (ComputeShares, drawOne).
local function categoryEnabled(cat, filter)
    local cfg = MIR.Config
    if (cfg.categoryWeights[cat] or 0) <= 0 then return false end
    -- v1.1.2 (plan review SF-3): belt and braces with the per-entry scope { treasure } - the
    -- allow-list category is drawable in chests and nowhere else.
    if cat == "extra" and not (filter and filter.class == "treasure") then return false end
    if (cat == "vanityClothing" or cat == "vanityBoots" or cat == "underwear") and not cfg.includeCosmetics then
        -- v0.8 ruling (Alan): a per-container content filter WINS LOCALLY. A wardrobe asked
        -- for cosmetic garments admits them even while the Pool-tab master switch is off,
        -- otherwise 'Wardrobes: cosmetic garments' would silently deliver stat armour
        -- instead (review B2). Cosmetics are always in the catalogue, so this costs nothing.
        if not (filter and filter.allowCosmetics) then return false end
    end
    -- v0.9: consumables are gated the same way cosmetics are. They enter the catalogue
    -- when a Pool toggle asks for them OR when a barrel / vase box does; if only those
    -- asked, they may be drawn ONLY there. Keyed on filter.allowConsumables, which
    -- ONLY the barrel and vase branches set - NOT on filter.allowed[cat], because the wardrobe
    -- "everything" option puts all three consumable categories into
    -- filter.allowed and would otherwise leak them into wardrobes (review BL-2).
    -- v1.0.1: this category-level gate is now a SECOND line of defence - the per-entry
    -- scope (entryAllowedFor) is what actually keeps clutter-only entries out of chests.
    if CONSUMABLE_CATS[cat]
       and not (cfg.includeConsumablesModded or cfg.includeConsumablesBase) then
        if not (filter and filter.allowConsumables) then return false end
    end
    -- v1.0: scrolls, same shape. Keyed on filter.allowScrolls, which ONLY the bookshelf
    -- branch and barrel/vase "everything" set (v1.1) - never on filter.allowed[cat].
    if SCROLL_CATS[cat] and not cfg.includeScrolls then
        if not (filter and filter.allowScrolls) then return false end
    end
    if filter and filter.allowed and not filter.allowed[cat] then return false end


    -- consumable slices (potion/arrow/alchemyIngredient/scroll) only exist if
    -- they were admitted at catalog build
    return true
end

-- ---------------- the MIR Browser status panel (v1.0) ----------------
-- The browser used to carry an include checkbox per category. It is gone (Config.lua says
-- why). Each row now shows a DERIVED status, computed from the container classes that are
-- actually enabled:
--   on      - the category competes with at least one OTHER category in at least one enabled
--             class. The slider is live and its percentage applies in those classes.
--   limited - drawable, but in EVERY class where it is drawable it is the ONLY category
--             allowed (e.g. scrolls with bookshelves = scrolls only). 100% there; the slider
--             is disabled because a relative weight has nothing to be relative to.
--   off     - drawable in no enabled class: weight 0, or gated by a Pool toggle that no
--             enabled class overrides locally. The REASON is reported.
--   empty   - no items in the pool at all (kept distinct - review BL-8 - so an empty
--             category can never read as ON, and never makes a class LIMITED).
-- Alan's rule, verbatim (2026-09-01): "the slider is active if the item category is mixed in
-- any container with other items (whether or not that is all containers, or just a category
-- of containers) and the percentage will apply to that container."
-- Percentages are per class: weight / sum of weights over that class's competing set. Classes
-- with the IDENTICAL competing set are grouped and shown once; different sets are shown
-- separately, each labelled with its containers. They are NEVER averaged across containers
-- that do not share a pool.
-- Like the old shares, these ignore the rarity window (a level-independent upper bound), so
-- the panel does not need republishing on every level-up; !mir_rarity has the live count.
-- Cost: 6 loot sources x 17 categories of cheap config tests, once per panel refresh. Never on a tick.
local CATEGORY_LABEL = {
    weapon = "Weapons", shield = "Shields", torso = "Body armour", helmet = "Helmets",
    gloves = "Gloves", boots = "Boots", cloak = "Cloaks", ring = "Rings", amulet = "Amulets",
    vanityClothing = "Camp clothing", vanityBoots = "Camp shoes", underwear = "Underwear",
    potion = "Potions and elixirs", arrow = "Arrows", alchemyIngredient = "Alchemy ingredients",
    scroll = "Scrolls", extra = "Extra items (chests only)",
}
local CLASS_ORDER = MIR.SourceKeys  -- v1.1: treasure, corpse, clutter, vase, wardrobe, bookshelf
local CLASS_LABEL = MIR.SourceNames

local function classEnabled(class)
    local cfg = MIR.Config
    if class == "treasure" then return cfg.includeChests ~= false end -- v1.1.1: chests have a switch
    if class == "corpse" then return cfg.includeCorpses and true or false end
    if class == "clutter" then return cfg.includeClutterContainers and true or false end
    if class == "vase" then return cfg.includeVases and true or false end
    if class == "wardrobe" then return cfg.includeWardrobes and true or false end
    if class == "bookshelf" then return cfg.includeBookshelves and true or false end
    return false
end

local function poolHasItems(cat)
    local slices = MIR.Catalog.built and MIR.Catalog.pool[cat] or nil
    if not slices then return false end
    for _, tier in ipairs(MIR.TierName) do
        local s = slices[tier]
        if s and #s > 0 then return true end
    end
    return false
end
-- v1.0.1: "does this CLASS have anything to draw from this category" - clutter-only arrows
-- do not count for chests. Early-exit scan; bounded by the pool, once per panel refresh.
local function poolHasItemsFor(cat, class)
    local slices = MIR.Catalog.built and MIR.Catalog.pool[cat] or nil
    if not slices then return false end
    local pseudo = { class = class }
    for _, tier in ipairs(MIR.TierName) do
        if sliceHasAllowed(slices[tier], pseudo) then return true end
    end
    return false
end

-- v1.1 (delta review SF-C): the loot-source boxes that could admit a GATED category locally
-- (consumables, camp clothing, scrolls), each with whether its box is ticked and whether its
-- source is switched on - so a reason can name the box that is actually off.
local SOURCE_UI = { clutter = "Barrels & crates", vase = "Vases & urns", wardrobe = "Wardrobes",
                    bookshelf = "Bookshelves" }
local function localAdmitters(cat)
    local cfg = MIR.Config
    local rows = {}
    local function add(source, box, boxOn, srcOn)
        rows[#rows + 1] = { source = source, box = box, boxOn = boxOn and true or false,
                            srcOn = srcOn and true or false }
    end
    local box = MIR.ConsumableBox[cat]
    if box then
        add("clutter", box:lower() .. " or everything", cfg["clutter" .. box] or cfg.clutterAllItems, cfg.includeClutterContainers)
        add("vase", box:lower() .. " or everything", cfg["vase" .. box] or cfg.vaseAllItems, cfg.includeVases)
    elseif COSMETIC_CATS[cat] then
        add("wardrobe", "cosmetic clothes or everything", cfg.wardrobeCosmetics or cfg.wardrobeAllItems, cfg.includeWardrobes)
        add("clutter", "everything", cfg.clutterAllItems, cfg.includeClutterContainers)
        add("vase", "everything", cfg.vaseAllItems, cfg.includeVases)
    elseif SCROLL_CATS[cat] then
        add("bookshelf", "scrolls", cfg.bookshelfScrolls, cfg.includeBookshelves)
        add("clutter", "everything", cfg.clutterAllItems, cfg.includeClutterContainers)
        add("vase", "everything", cfg.vaseAllItems, cfg.includeVases)
    end
    return rows
end
local function anyLocalAdmitter(cat)
    for _, r in ipairs(localAdmitters(cat)) do
        if r.boxOn and r.srcOn then return true end
    end
    return false
end
-- A box that is ticked under a switched-off source is named FIRST: telling a user to tick a
-- box that is already ticked is how the v1.0.0 bug report happened (v1.0.1 plan review SF-2).
local function gatedReason(cat, poolFix)
    local rows = localAdmitters(cat)
    for _, r in ipairs(rows) do
        if r.boxOn and not r.srcOn then
            return ("%s would admit it but that loot source is switched off (Loot Source Settings); or %s")
                :format(SOURCE_UI[r.source] or r.source, poolFix)
        end
    end
    local names = {}
    for _, r in ipairs(rows) do names[#names + 1] = (SOURCE_UI[r.source] or r.source) .. ": " .. r.box end
    if #names == 0 then return poolFix end
    return poolFix .. ", or tick it for a loot source (" .. table.concat(names, "; ") .. ")"
end

-- Why a category with items is drawable nowhere (review SF-2: the reasons must survive).
local function offReason(cat)
    local cfg = MIR.Config
    if (cfg.categoryWeights[cat] or 0) <= 0 then return "weight 0" end
    if cat == "extra" then
        if not classEnabled("treasure") then return "chests are switched off (extra items appear in chests only)" end
        return "extra items appear in chests only"
    end
    if COSMETIC_CATS[cat] and not cfg.includeCosmetics then
        return gatedReason(cat, "enable cosmetics on the Pool tab")
    end
    if CONSUMABLE_CATS[cat] and not (cfg.includeConsumablesModded or cfg.includeConsumablesBase) then
        return gatedReason(cat, "enable consumables on the Pool tab")
    end
    if SCROLL_CATS[cat] and not cfg.includeScrolls then
        return gatedReason(cat, "enable scrolls on the Pool tab")
    end
    return "no enabled loot source allows it"
end

-- Why the pool holds nothing for a category, when the answer is a setting rather than
-- the load order (these categories are gated at CATALOG BUILD, so "no items" is misleading).
local function emptyReason(cat)
    local cfg = MIR.Config
    if cat == "extra" then
        if next(cfg.extraChestItems or {}) == nil then
            return "the extra-items list is empty - add one with !mir_extra add <stat name>, or on the Exclusion lists tab"
        end
        return "nothing in the extra-items list matched an item in this load order"
    end
    if CONSUMABLE_CATS[cat] then
        local anyPool = cfg.includeConsumablesModded or cfg.includeConsumablesBase
        local localOn = anyLocalAdmitter(cat)
        -- v1.0.1 (plan review SF-2): name the switch that is ACTUALLY off.
        if not anyPool and not localOn then
            return "not admitted - " .. gatedReason(cat, "enable a consumables setting on the Pool tab (everywhere)")
        end
        if not cfg.includeConsumablesBase and not localOn then
            return "no mod in your load order adds any; vanilla ones need 'Include base-game consumables' (everywhere), or a ticked box under Barrels & crates or Vases & urns (there only)"
        end
        return nil -- genuinely nothing exists, vanilla included
    end
    if SCROLL_CATS[cat] and not cfg.includeScrolls and not anyLocalAdmitter(cat) then
        return "scrolls are off - " .. gatedReason(cat, "enable them on the Pool tab")
    end
    return nil
end

function MIR.ComputeShares()
    local cfg = MIR.Config
    -- Diff review SF-3: before the catalogue is built every row would read "no items in
    -- pool", which is false (they have not been counted yet) and reads as "MIR found nothing".
    if not MIR.Catalog.built then
        local rows = {}
        for cat, w in pairs(cfg.categoryWeights) do
            rows[#rows + 1] = { cat = cat, label = CATEGORY_LABEL[cat] or cat, weight = tonumber(w) or 0,
                                status = "empty", text = "catalogue not built yet (load a save)",
                                hasItems = false, active = false, drawableIn = {} }
        end
        return rows
    end
    -- 1. the competing set of every ENABLED class: categories drawable there that have items
    local sets = {} -- [class] = { cats = set, n = count, key = "a,b,c" }
    for _, class in ipairs(CLASS_ORDER) do
        if classEnabled(class) then
            local f = MIR.ContentFilterFor(class)
            if not f.nothing then
                local cats, names = {}, {}
                for cat in pairs(cfg.categoryWeights) do
                    -- v1.0.1: per-CLASS presence, so clutter-only arrows never count for chests
                    if categoryEnabled(cat, f) and poolHasItemsFor(cat, class) then
                        cats[cat] = true
                        names[#names + 1] = cat
                    end
                end
                table.sort(names)
                sets[class] = { cats = cats, n = #names, key = table.concat(names, ",") }
            end
        end
    end

    local enabledClasses = 0
    for _ in pairs(sets) do enabledClasses = enabledClasses + 1 end

    -- 2. one row per category
    local rows = {}
    for cat, w in pairs(cfg.categoryWeights) do
        local weight = tonumber(w) or 0
        local hasItems = poolHasItems(cat)
        local drawableIn, mixed = {}, false
        for _, class in ipairs(CLASS_ORDER) do
            local s = sets[class]
            if s and s.cats[cat] then
                drawableIn[#drawableIn + 1] = class
                if s.n > 1 then mixed = true end
            end
        end

        local status, reason, groups, pct = "off", nil, nil, nil
        if #drawableIn > 0 then
            status = mixed and "on" or "limited"
            -- per-class share, grouped by identical competing set (never averaged)
            groups = {}
            local byKey = {}
            for _, class in ipairs(drawableIn) do
                local s = sets[class]
                local g = byKey[s.key]
                if not g then
                    local total = 0
                    for c in pairs(s.cats) do total = total + (tonumber(cfg.categoryWeights[c]) or 0) end
                    g = { classes = {}, pct = (total > 0) and (100 * weight / total) or 0 }
                    byKey[s.key] = g
                    groups[#groups + 1] = g
                end
                g.classes[#g.classes + 1] = CLASS_LABEL[class] or class
            end
            if #groups == 1 then pct = groups[1].pct end
        elseif not hasItems then
            status = "empty"
            reason = emptyReason(cat)
        else
            reason = offReason(cat)
        end

        -- the display text is built HERE so the client stays dumb and cannot mislabel a state
        local text
        if status == "on" then
            -- v1.0.1 (plan review SF-4): a single figure is labelled with WHERE it applies
            -- whenever the category is not drawable in every enabled container type - the
            -- whole point of the row is to say where a category spawns.
            if #groups == 1 and #drawableIn >= enabledClasses then
                text = ("ON  %.1f%%"):format(groups[1].pct)
            elseif #groups == 1 then
                text = ("ON  %.1f%% (%s)"):format(groups[1].pct, table.concat(groups[1].classes, ", "))
            else
                local parts = {}
                for _, g in ipairs(groups) do
                    parts[#parts + 1] = ("%.1f%% (%s)"):format(g.pct, table.concat(g.classes, ", "))
                end
                text = "ON  " .. table.concat(parts, " | ")
            end
        elseif status == "limited" then
            local where = {}
            for _, class in ipairs(drawableIn) do where[#where + 1] = CLASS_LABEL[class] or class end
            text = ("LIMITED  100%% - the only category allowed in %s; slider inactive"):format(table.concat(where, ", "))
        elseif status == "empty" then
            text = "OFF  no items in pool" .. (reason and (" - " .. reason) or "")
        else
            text = "OFF  " .. tostring(reason or "off")
        end
        if RARITY_EXEMPT_CATS[cat] and (status == "on" or status == "limited") then
            text = text .. "  - no rarity window"
        end

        rows[#rows + 1] = { cat = cat, label = CATEGORY_LABEL[cat] or cat, weight = weight,
                            status = status, text = text, reason = reason, pct = pct,
                            groups = groups, drawableIn = drawableIn, hasItems = hasItems,
                            active = (status == "on" or status == "limited") }
    end
    -- no sort: every consumer (SharesPayload, !mir_share list) orders by SHARE_ORDER itself
    return rows
end

local function weightedPick(options) -- options = { {key=..., weight=...}, ... }
    local total = 0
    for _, o in ipairs(options) do total = total + o.weight end
    if total <= 0 then return nil end
    local r = math.random() * total
    for _, o in ipairs(options) do
        r = r - o.weight
        if r <= 0 then return o.key end
    end
    return options[#options].key
end

-- One roll: returns entry, or nil plus a REASON (review S6 - 'nothing matches this
-- container's content filter' and 'the pool is empty' are different problems and the
-- player needs to be able to tell them apart).
-- v1.0.1: every stage tests entryAllowedFor, so a clutter-only entry is never a candidate
-- for a chest. Reasons, evaluated in this order once stage 1 finds no category
-- (plan review SF-3):
--   filter    - an UNRESTRICTED container of this class would find something: the content
--               filter is the only thing in the way
--   window    - something this container may hold exists, but nothing inside the rarity window
--   scoped    - something inside the window exists, but all of it is reserved for another
--               loot source (barrel-, vase- or bookshelf-only entries)
--   exhausted - the pool really has nothing for this container
local function drawOne(filter)
    local cfg = MIR.Config
    local pool = MIR.Catalog.pool
    local minTier, maxTier = effectiveRarityWindow()

    for _ = 1, 4 do -- bounded redraws (single-pass in practice since v1.0.1)
        -- 1. weighted category pick among enabled categories with an ALLOWED item in range
        local catOptions = {}
        for cat, slices in pairs(pool) do
            if categoryEnabled(cat, filter) then
                local lo, hi = tierRangeFor(cat, minTier, maxTier)
                if catHasAllowedInRange(slices, lo, hi, filter) then
                    catOptions[#catOptions + 1] = { key = cat, weight = cfg.categoryWeights[cat] or 1 }
                end
            end
        end
        local cat = weightedPick(catOptions)
        if not cat then
            -- (a) would an UNRESTRICTED container of this class find something? -> the content filter
            if filter and (filter.allowed or filter.allowCosmetics ~= nil
                           or filter.allowConsumables ~= nil or filter.allowScrolls ~= nil) then
                for c2, sl2 in pairs(pool) do
                    if categoryEnabled(c2, nil) then
                        local lo, hi = tierRangeFor(c2, minTier, maxTier)
                        if catHasAllowedInRange(sl2, lo, hi, filter) then return nil, "filter" end
                    end
                end
            end
            -- (b) would the FULL rarity range find something this container may hold? -> the window
            -- (review SF-4: "nothing inside your rarity window" and "the pool is empty" are
            -- different problems and the player has to be able to tell them apart)
            if cfg.rarityWindow and cfg.rarityWindow.enabled then
                for c2, sl2 in pairs(pool) do
                    if categoryEnabled(c2, filter) and catHasAllowedInRange(sl2, 1, 5, filter) then
                        return nil, "window"
                    end
                end
            end
            -- (c) is there anything inside the window at all, just reserved elsewhere? -> scoped
            for c2, sl2 in pairs(pool) do
                if categoryEnabled(c2, filter) then
                    local lo, hi = tierRangeFor(c2, minTier, maxTier)
                    for t2 = lo, hi do
                        local s2 = sl2[MIR.TierName[t2]]
                        if s2 and #s2 > 0 then return nil, "scoped" end
                    end
                end
            end
            return nil, "exhausted"
        end

        -- 2. equal-weight rarity pick among permitted tiers holding an allowed entry
        local lo, hi = tierRangeFor(cat, minTier, maxTier)
        local tierOptions = {}
        for tier = lo, hi do
            if sliceHasAllowed(pool[cat][MIR.TierName[tier]], filter) then
                tierOptions[#tierOptions + 1] = { key = tier, weight = 1 }
            end
        end
        local tier = weightedPick(tierOptions)
        if tier then
            -- 3. uniform over the entries THIS container may hold (a filtered copy: draws are
            -- rare - one per container open - and the largest slice is a few hundred entries)
            local allowed = {}
            for _, e in ipairs(pool[cat][MIR.TierName[tier]] or {}) do
                if entryAllowedFor(e, filter) then allowed[#allowed + 1] = e end
            end
            if #allowed > 0 then return allowed[math.random(#allowed)] end
        end
    end
    return nil, "exhausted"
end

-- v1.0: when a roll succeeds but the container's content filter matches nothing, NAME each
-- allowed category and say why it cannot draw. The v0.9 line was accurate but not
-- actionable - it knew which categories were off and did not say (Alan, 2026-09-01).
local function explainFilterMiss(filter)
    local cfg = MIR.Config
    local pool = MIR.Catalog.pool or {}
    local minTier, maxTier = effectiveRarityWindow()
    local names = {}
    for c in pairs(filter and filter.allowed or {}) do names[#names + 1] = c end
    table.sort(names)
    if #names == 0 then return "(the filter allows no categories at all)" end
    local parts = {}
    for _, c in ipairs(names) do
        local why
        if (cfg.categoryWeights[c] or 0) <= 0 then
            why = "weight 0 on the MIR Browser tab"
        elseif c == "extra" then
            why = "extra items appear in chests only"
        elseif not categoryEnabled(c, filter) then
            why = "switched off on the Pool tab"
        else
            -- v1.0.1: judged over the entries THIS container may hold (plan review SF-3)
            local slices, rawAny, allowedAny, allowedInWindow = pool[c], false, false, false
            local lo, hi = tierRangeFor(c, minTier, maxTier)
            for t = 1, 5 do
                local s = slices and slices[MIR.TierName[t]] or nil
                if s and #s > 0 then
                    rawAny = true
                    if sliceHasAllowed(s, filter) then
                        allowedAny = true
                        if t >= lo and t <= hi then allowedInWindow = true end
                    end
                end
            end
            if not rawAny then why = "no items in pool"
            elseif not allowedAny then why = "no items drawable here (reserved for other loot sources)"
            elseif not allowedInWindow then why = "nothing inside your rarity window"
            else why = "?" end
        end
        parts[#parts + 1] = c .. " (" .. why .. ")"
    end
    return table.concat(parts, ", ")
end

-- v1.1 (Alan, 2026-09-10): chance and rolls per LOOT SOURCE. A source whose own box is ticked
-- uses its own pair; everything else uses the General pair. The ONE place that decides, so the
-- listeners, the zero test, the dry run, the roll loop and !mir_status cannot drift (delta
-- review M-4). nil class -> General.
function MIR.EffectiveChanceRolls(class)
    local cfg = MIR.Config
    if class and cfg.sourceOwn and cfg.sourceOwn[class] then
        return tonumber(cfg.sourceChancePct[class]) or cfg.baseChancePct,
               tonumber(cfg.sourceRolls[class]) or cfg.rolls, true
    end
    return cfg.baseChancePct, cfg.rolls, false
end

-- Inject up to the source's roll count of items into targetOsi. Returns number injected.
local function rollAndInject(targetOsi, sourceTag, filter)
    local cfg = MIR.Config
    local chance, rolls, own = MIR.EffectiveChanceRolls(filter and filter.class)
    if cfg.dryRun then
        -- review S1: the dry line used to say nothing about WHY a container would or
        -- would not produce anything, which is useless for testing the content filters.
        local what = "all items"
        if filter and filter.allowed then
            local names = {}
            for c in pairs(filter.allowed) do names[#names + 1] = c end
            table.sort(names)
            what = #names > 0 and table.concat(names, ",") or "NOTHING"
        end
        log(("%s: DRYRUN - would roll %dx @ %d%% (%s) on %s [class=%s allowed=%s]%s"):format(
            sourceTag, rolls, chance, own and "own" or "general", namePart(targetOsi),
            tostring(filter and filter.class or "?"), what,
            (chance <= 0 or rolls <= 0) and " - chance or rolls is 0: would skip (retryable)" or ""))
        return 0
    end

    local injected = 0
    for _ = 1, rolls do
        if math.random(100) <= chance then
            local entry, why = drawOne(filter)
            if not entry then
                if why == "filter" then
                    logOnce("filter:" .. tostring(filter and filter.class or "?"), ("%s: roll succeeded but NOTHING IN THE POOL MATCHES THIS CONTAINER'S CONTENT FILTER"
                        .. " (class=%s) - no-op. It allows: %s. Loosen the filter for this container"
                        .. " type, or fix the category it needs (!mir_pool for counts). Logged once per loot source until settings change.")
                        :format(sourceTag, tostring(filter and filter.class or "?"), explainFilterMiss(filter)))
                elseif why == "window" then
                    local mn, mx = MIR.EffectiveRarityWindow()
                    log(("%s: roll succeeded but NOTHING IN THE POOL IS INSIDE YOUR RARITY WINDOW"
                        .. " (%s..%s) - no-op. Widen it on the Rarity tab, or run !mir_rarity to see"
                        .. " how many items actually fall inside it.")
                        :format(sourceTag, tostring(MIR.TierName[mn]), tostring(MIR.TierName[mx]))) 
                elseif why == "scoped" then
                    log(("%s: roll succeeded but EVERYTHING LEFT THAT MATCHES IS RESERVED FOR ANOTHER"
                        .. " LOOT SOURCE (barrel-, vase- or bookshelf-only items) - no-op for class=%s."
                        .. " !mir_pool shows the scoped counts.")
                        :format(sourceTag, tostring(filter and filter.class or "?")))
                else
                    log(sourceTag .. ": roll succeeded but the pool is empty - no-op")
                end


            else
                local ok, err = pcall(function()
                    Osi.TemplateAddTo(entry.template, targetOsi, 1, cfg.notifySpawns and 1 or 0)
                end)
                if ok then
                    -- No-duplicate applies to EQUIPMENT only (§5 Q3 answer):
                    -- consumables stay in the pool and can drop repeatedly.
                    -- entry.consumable covers ALL consumable categories (B1 fix:
                    -- a literal category-name test broke with the potion/arrow/
                    -- alchemyIngredient split).
                    if not entry.consumable then
                        MIR.RemoveFromPool(entry.template)
                        ledgerAdd(entry.template, guid36(targetOsi))
                    end
                    injected = injected + 1
                    log(sourceTag .. ": SPAWNED " .. entry.stat .. " (" .. entry.rarity .. " " .. entry.category
                        .. ") -> " .. tostring(targetOsi))
                    flush() -- spawns are rare and load-bearing; never leave one in the throttled buffer
                else
                    log(sourceTag .. ": TemplateAddTo FAILED (" .. tostring(err) .. ") - item stays in pool")
                end
            end
        end
    end
    return injected
end

-- ---------------- guards + hooks ----------------
local function commonGuards()
    -- Hard dependency gate (Alan 2026-08-24): with MCM absent the user has no way
    -- to configure or disable MIR, so MIR does nothing at all.
    if MIR.McmMissing then return false end
    if not MIR.Config.enabled then return false end
    if not gameplayActive then return false end
    if MIR.Config.excludeNautiloid and currentLevel == "TUT_Avernus_C" then return false end
    if not MIR.Catalog.built then return false end
    hydrateLedger()
    return true
end

-- v0.9: `ensureConsumablesForClutter` DELETED. v0.8 worked around consumables being dropped
-- at catalog build by turning the Pool toggle ON for the user and rebuilding - which made
-- them pool-wide, so they also appeared in chests and on corpses. Alan asked for clutter
-- ONLY, so admission now happens in Catalog.lua (consumables, when clutter asks - vanilla
-- AND modded since v1.0.1) and enforcement at draw time via the per-entry scope plus
-- filter.allowConsumables. MIR no longer edits any user setting.

Ext.Osiris.RegisterListener("TemplateOpening", 3, "before", function(template, item, character)
    local ok, err = pcall(function()
        if not commonGuards() then return end
        if Osi.IsContainer(item) ~= 1 then return end
        if Osi.IsPlayer(character) ~= 1 then return end
        local u = guid36(item)
        if isProcessed(u) then return end
        -- never touch containers carried in anyone's inventory (Phase 0: player bags fire this event)
        if hasComponent(u, "InventoryMember") then return end
        -- never touch owned containers (theft inheritance, Phase 0-confirmed)
        local owner = tostring(Osi.GetOwner(item) or "")
        if owner ~= "" and owner:sub(1, 4) ~= "NULL" then
            log("Container SKIP owned: " .. namePart(item) .. " owner=" .. owner)
            markProcessed(u, "owned")
            return
        end
        local tier = classifyContainer(template, item)
        log("Container tier=" .. tier .. " root=" .. namePart(template) .. " inst=" .. namePart(item))
        if tier == "excluded" then markProcessed(u, "excluded") return end
        if tier == "clutter" and not MIR.Config.includeClutterContainers then
            markProcessed(u, "clutter")
            return
        end
        -- v1.1.1 (Alan, 2026-09-13): chests have a switch. Skipped WITHOUT a stamp (plan review SF-1):
        -- nothing was consumed, and an unstamped chest stays eligible on every version, including
        -- after a rollback. MIR.Config, not cfg - this listener has no cfg local (plan review BL-1).
        if tier == "treasure" and MIR.Config.includeChests == false then
            return
        end
        if tier == "wardrobe" and not MIR.Config.includeWardrobes then
            markProcessed(u, "wardrobe")
            return
        end
        if tier == "bookshelf" and not MIR.Config.includeBookshelves then
            markProcessed(u, "bookshelf")
            return
        end
        if tier == "vase" and not MIR.Config.includeVases then
            markProcessed(u, "vase")
            return
        end
        local filter = MIR.ContentFilterFor(tier)
        if filter.nothing then
            -- v1.0 bookshelves, v1.1 every boxed source: nothing ticked contributes NOTHING
            -- (review BL-1). Stamped with the RETRYABLE class note, so it comes back if a box
            -- is ticked later. Logged once per source (delta review M-2).
            logOnce("nothing:" .. tier, ("Container: %s class=%s has nothing ticked in its loot-source"
                .. " settings - skipped; it will be re-evaluated if you tick something (logged once per"
                .. " source until settings change)"):format(namePart(item), tier))
            markProcessed(u, tier)
            return
        end
        -- v1.1 (plan review BL-1): a chance or roll count of 0 rolls nothing, so nothing was
        -- consumed - stamp RETRYABLE, never the terminal rolled:0 that would burn the container.
        -- A dry run still goes through rollAndInject so the survey line is printed (M-3).
        local chance, rolls = MIR.EffectiveChanceRolls(tier)
        if (chance <= 0 or rolls <= 0) and not MIR.Config.dryRun then
            logOnce("zero:" .. tier, ("Container: class=%s has chance %d%% x %d roll(s) - not rolled;"
                .. " containers stay eligible and roll once you raise it (logged once per source)")
                :format(tier, chance, rolls))
            markProcessed(u, "zero")
            return
        end
        local n = rollAndInject(item, "Container", filter)
        -- review S1: a dry run must NOT burn the container - dry-run is the obvious way to
        -- survey the new container classes, and 'rolled:0' would have killed every wardrobe
        -- it looked at. 'dryrun' is a RETRY_NOTES reason, so it stays re-evaluable.
        markProcessed(u, MIR.Config.dryRun and "dryrun" or ("rolled:" .. n))

    end)
    if not ok then log("TemplateOpening handler ERROR: " .. tostring(err)) end
end)

Ext.Osiris.RegisterListener("RequestCanLoot", 2, "before", function(looter, target)
    local ok, err = pcall(function()
        if not MIR.Config.includeCorpses then return end
        if not commonGuards() then return end
        if Osi.IsDead(target) ~= 1 then return end
        if Osi.IsPlayer(target) == 1 then return end
        local u = guid36(target)
        if isProcessed(u) then return end
        log("Corpse evaluated: " .. namePart(target))
        -- M-2: give the corpse path a real class so the dry-run line reads class=corpse
        -- rather than class=?. The corpse filter is unrestricted, as it always was.
        -- v1.1 (plan review BL-1): chance or rolls 0 -> not rolled, stamped RETRYABLE
        local chance, rolls = MIR.EffectiveChanceRolls("corpse")
        if (chance <= 0 or rolls <= 0) and not MIR.Config.dryRun then
            logOnce("zero:corpse", ("Corpse: chance %d%% x %d roll(s) - not rolled; corpses stay"
                .. " eligible and roll once you raise it (logged once)"):format(chance, rolls))
            markProcessed(u, "zero")
            return
        end
        local n = rollAndInject(target, "Corpse", MIR.ContentFilterFor("corpse"))
        -- BL-1: this was still stamping "rolled:0" under !mir_dry, which is TERMINAL - so a
        -- dry-run survey silently killed MIR loot on every corpse it looked at, forever. The
        -- container path already had this fix; the corpse path was missed.
        markProcessed(u, MIR.Config.dryRun and "dryrun" or ("rolled:" .. n))

    end)
    if not ok then log("RequestCanLoot handler ERROR: " .. tostring(err)) end
end)

-- Level-key -> Act map (for the rarity-window Act rules and future Act multipliers).
-- Sources: REL_SE's region map + vanilla level keys. TODO: verify SCL/INT/IRN keys in-game.
local LEVEL_TO_ACT = {
    TUT_Avernus_C = 1, WLD_Main_A = 1, CRE_Main_A = 1,
    SCL_Main_A = 2, INT_Main_A = 2, IRN_Main_A = 2,
    BGO_Main_A = 3, CTY_Main_A = 3, LOW_Main_A = 3, END_Main = 3,
}

Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "before", function(levelName, isEditorMode)
    local ok = pcall(function()
        currentLevel = tostring(levelName)
        MIR.CurrentAct = LEVEL_TO_ACT[currentLevel] or MIR.CurrentAct or 1
        gameplayActive = true
        log("LevelGameplayStarted: " .. currentLevel .. " (act " .. tostring(MIR.CurrentAct) .. ", gameplay active)")
        -- Tell the PLAYER (not just the log) that MIR switched itself off, once
        -- per session. Cannot use MCM for this — MCM is the missing thing.
        -- Rebroadcast on every level start (review SF1): the CLIENT latch dedupes,
        -- so a once-only server latch would only convert a dropped message or a
        -- late-joining peer into "the player never finds out".
        if MIR.McmMissing then
            pcall(function()
                if MIRNet and MIRNet.Notice then
                    MIRNet.Notice:Broadcast({ kind = "mcm_missing" })
                end
            end)
        end
        flush()
    end)
    if not ok then log("LevelGameplayStarted handler ERROR") end
end)

Ext.Osiris.RegisterListener("SavegameLoadStarted", 0, "before", function()
    pcall(function()
        gameplayActive = false
        hydrated = false -- new save context; re-hydrate against its ledger
        log("SavegameLoadStarted (gameplay locked)")
        flush()
    end)
end)

Ext.Events.SessionLoaded:Subscribe(function()
    local ok, err = pcall(function()
        -- MCM values must land BEFORE the catalog builds (structural ordering, review S1)
        pcall(function() if MIR.SyncFromMCM then MIR.SyncFromMCM("session") end end)
        if MIR.McmMissing then
            log("MIR is dormant (MCM not installed): skipping catalog build entirely.")
            flush()
            return
        end
        local cat = MIR.BuildCatalog()
        local s = cat.stats
        -- 16 format specifiers / 16 arguments — keep them in sync when editing.
        log(("Catalog built in %d ms: eligible=%d of %d seen (base=%d story=%d noTpl=%d noName=%d dupe=%d unmappedSlot=%d excluded=%d treasureTable=%d consumableGated=%d uncategorisedModdedObjects=%d utilityStats=%d npcGearStats=%d; of the eligible, reserved for one loot source: %s)")
            :format(cat.builtMs, s.eligible, s.seen, s.skippedBase, s.skippedStory,
                    s.skippedNoTemplate, s.skippedNoName, s.skippedDupe, s.skippedUnmappedSlot, s.skippedExcluded, s.skippedTreasureTable, s.skippedConsumable, s.skippedUncategorised or 0, s.skippedUtilityStats, s.skippedNpcGearStats,
                    MIR.ScopedSummary(s)))
        if MIR.PublishShares then MIR.PublishShares() end
        flush()
    end)
    if not ok then log("SessionLoaded ERROR: " .. tostring(err)); flush() end
end)

-- ---------------- console commands (server context, ! prefix) ----------------
-- v1.1: "rings,potions" / "everything" / "NOTHING" for a boxed source (!mir_status, commands)
local function boxesText(prefix)
    local cfg = MIR.Config
    if cfg[prefix .. "AllItems"] then return "everything" end
    local parts = {}
    for _, w in ipairs({ "Rings", "Potions", "Arrows", "Ingredients" }) do
        if cfg[prefix .. w] then parts[#parts + 1] = w:lower() end
    end
    return #parts > 0 and table.concat(parts, ",") or "NOTHING"
end

-- v1.1 console forms for the per-source values (first plan review SF-4, delta review SF-E). A
-- number ticks the source's own box (the value would do nothing while it is unticked);
-- "general" unticks it.
local SOURCE_ALIASES = { chests = "treasure", chest = "treasure", treasure = "treasure",
    corpses = "corpse", corpse = "corpse", barrels = "clutter", barrel = "clutter", crates = "clutter",
    clutter = "clutter", vases = "vase", vase = "vase", urns = "vase", wardrobes = "wardrobe",
    wardrobe = "wardrobe", bookshelves = "bookshelf", bookshelf = "bookshelf",
    -- diff review M-5: the other names the MCM sections use
    crate = "clutter", urn = "vase", jar = "vase", jars = "vase", amphora = "vase", amphorae = "vase",
    closet = "wardrobe", closets = "wardrobe", desk = "bookshelf", desks = "bookshelf" }
local function setSourceValue(src, what, v, maxV)
    local cfg = MIR.Config
    local n = tonumber(v)
    if v == "general" then
        cfg.sourceOwn[src] = false
        MIR.MarkConsoleOverride("mir_own_" .. src)
    elseif n and n >= 0 and n <= maxV then
        n = math.floor(n)
        if what == "chance" then cfg.sourceChancePct[src] = n else cfg.sourceRolls[src] = n end
        cfg.sourceOwn[src] = true
        MIR.MarkConsoleOverride("mir_own_" .. src)
        MIR.MarkConsoleOverride("mir_" .. what .. "_" .. src)
    elseif v ~= nil and v ~= "" then
        log(("usage: !mir_%s <source> <0-%d|general>"):format(what, maxV))
    end
    if MIR.ResetOnceLogged then MIR.ResetOnceLogged() end
    local c, r, own = MIR.EffectiveChanceRolls(src)
    log(("%s: %d%% x %d roll(s) (%s)"):format(MIR.SourceNames[src] or src, c, r,
        own and "its own values" or "the General values"))
end
Ext.RegisterConsoleCommand("mir_status", function()
    local cfg = MIR.Config
    local _, t = ledgerGet()
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    log(("status: enabled=%s gameplayActive=%s level=%s catalogBuilt=%s generalRolls=%d generalChance=%d%% utilExclude=%s mcm=%s ledger=%d spawned")
        :format(tostring(cfg.enabled), tostring(gameplayActive), currentLevel,
                tostring(MIR.Catalog.built), cfg.rolls, cfg.baseChancePct, tostring(cfg.excludeUtilityMods),
                MIR.McmMissing and "MISSING - MIR DORMANT" or (MIR.McmDetected and "detected" or "pending"), n))
    -- review S5: five more invisible container gates would make "why did my wardrobe do
    -- nothing?" unanswerable from the log. Surface every target gate and its content filter.
    do -- v0.9 (review S5/M7): the window in TIER NAMES, plus the level and Act it came from
        local mn, mx, info = MIR.EffectiveRarityWindow()
        if MIR.Config.rarityWindow.enabled then
            log(("  rarity window: %s..%s  (level=%s act=%s) - !mir_rarity for the rules")
                :format(tostring(MIR.TierName[mn]), tostring(MIR.TierName[mx]),
                        tostring(info.lvl or "?"), tostring(info.act or "?")))
        else
            log("  rarity window: off (every rarity can spawn)")
        end
    end
    log(("  targets: corpses=%s chests=%s barrels=%s(%s) vases=%s(%s) wardrobes=%s(cosmetics=%s stat=%s everything=%s) bookshelves=%s(scrolls=%s alsoAllItems=%s)")
        :format(tostring(cfg.includeCorpses), tostring(cfg.includeChests ~= false),
                tostring(cfg.includeClutterContainers), boxesText("clutter"),
                tostring(cfg.includeVases), boxesText("vase"),
                tostring(cfg.includeWardrobes),
                tostring(cfg.wardrobeCosmetics), tostring(cfg.wardrobeStatGarments),
                tostring(cfg.wardrobeAllItems), tostring(cfg.includeBookshelves),
                tostring(cfg.bookshelfScrolls), tostring(cfg.bookshelfAllItems)))
    do -- v1.1: what each loot source actually rolls with
        local parts = {}
        for _, k in ipairs(MIR.SourceKeys) do
            local c, r, own = MIR.EffectiveChanceRolls(k)
            parts[#parts + 1] = ("%s %d%% x%d%s"):format(MIR.SourceNames[k] or k, c, r, own and " (own)" or "")
        end
        log("  chance x rolls: " .. table.concat(parts, ", "))
    end
    do -- v1.1.2: the extra-items allow-list
        local n = 0
        for _ in pairs(cfg.extraChestItems or {}) do n = n + 1 end
        log("  extra items (chests only): " .. n .. " entr(ies) listed")
    end
    log(("  pool: baseGame=%s cosmetics=%s consumablesModded=%s consumablesBase=%s scrolls=%s utilityFence=%s placementFilter=%s")
        :format(tostring(cfg.includeBaseGame), tostring(cfg.includeCosmetics),
                tostring(cfg.includeConsumablesModded), tostring(cfg.includeConsumablesBase),
                tostring(cfg.includeScrolls), tostring(cfg.excludeUtilityMods),
                tostring(cfg.excludeTreasureTableItems)))

    flush()
end)

Ext.RegisterConsoleCommand("mir_pool", function()
    for _, l in ipairs(MIR.PoolCounts()) do log(l) end
    flush()
end)

Ext.RegisterConsoleCommand("mir_enable", function(_, v)
    if v == "on" then MIR.Config.enabled = true elseif v == "off" then MIR.Config.enabled = false end
    if v == "on" or v == "off" then MIR.MarkConsoleOverride("mir_enabled") end
    log("enabled=" .. tostring(MIR.Config.enabled))
    flush()
end)

-- v1.1: "<source> <n|general>" is parsed FIRST, so "!mir_chance 50" still sets the General value
Ext.RegisterConsoleCommand("mir_chance", function(_, v, v2)
    local src = v and SOURCE_ALIASES[tostring(v):lower()]
    if src then setSourceValue(src, "chance", v2, 100) flush() return end
    local n = tonumber(v)
    if n and n >= 0 and n <= 100 then
        MIR.Config.baseChancePct = math.floor(n)
        MIR.MarkConsoleOverride("mir_base_chance")
    elseif v ~= nil and v ~= "" then
        log("usage: !mir_chance <0-100>  |  !mir_chance <chests|corpses|barrels|vases|wardrobes|bookshelves> <0-100|general>")
    end
    log("baseChancePct=" .. MIR.Config.baseChancePct .. " (General - every source without its own chance)")
    flush()
end)

Ext.RegisterConsoleCommand("mir_rolls", function(_, v, v2)
    local src = v and SOURCE_ALIASES[tostring(v):lower()]
    if src then setSourceValue(src, "rolls", v2, 10) flush() return end
    local n = tonumber(v)
    if n and n >= 0 and n <= 10 then
        MIR.Config.rolls = math.floor(n)
        MIR.MarkConsoleOverride("mir_rolls")
    elseif v ~= nil and v ~= "" then
        log("usage: !mir_rolls <0-10>  |  !mir_rolls <chests|corpses|barrels|vases|wardrobes|bookshelves> <0-10|general>")
    end
    log("rolls=" .. MIR.Config.rolls .. " (General - every source without its own rolls)")
    flush()
end)

Ext.RegisterConsoleCommand("mir_rebuild", function()
    MIR.RebuildAndRehydrate("console")
end)

Ext.RegisterConsoleCommand("mir_dry", function(_, v)
    if v == "on" then MIR.Config.dryRun = true elseif v == "off" then MIR.Config.dryRun = false end
    log("dryRun=" .. tostring(MIR.Config.dryRun))
    flush()
end)

Ext.RegisterConsoleCommand("mir_flush", function()
    flush()
    log("log flushed to " .. LOGFILE)
    flush()
end)

Ext.RegisterConsoleCommand("mir_util", function(_, v)
    if v == "on" then MIR.Config.excludeUtilityMods = true
    elseif v == "off" then MIR.Config.excludeUtilityMods = false end
    log("excludeUtilityMods=" .. tostring(MIR.Config.excludeUtilityMods))
    if v == "on" or v == "off" then
        MIR.MarkConsoleOverride("mir_exclude_utility_mods")
        -- the fence operates at catalog build time -> rebuild + re-hydrate
        MIR.RebuildAndRehydrate("mir_util")
        log("(affects FUTURE containers/corpses only; already-processed ones never re-roll)")
    end
    flush()
end)

Ext.RegisterConsoleCommand("mir_consumables", function(_, v, v2)
    -- Phase 3 chunk-1 test aid (no MCM UI yet):
    --   !mir_consumables on|off        -> modded consumables
    --   !mir_consumables base on|off   -> BASE-GAME consumables (classifier probe)
    local changed = false
    if v == "base" then
        if v2 == "on" then MIR.Config.includeConsumablesBase = true changed = true
        elseif v2 == "off" then MIR.Config.includeConsumablesBase = false changed = true end
        if changed then MIR.MarkConsoleOverride("mir_include_consumables_base") end
    else
        if v == "on" then MIR.Config.includeConsumablesModded = true changed = true
        elseif v == "off" then MIR.Config.includeConsumablesModded = false changed = true end
        if changed then MIR.MarkConsoleOverride("mir_include_consumables_modded") end
    end
    log("includeConsumablesModded=" .. tostring(MIR.Config.includeConsumablesModded)
        .. " includeConsumablesBase=" .. tostring(MIR.Config.includeConsumablesBase))
    if changed then MIR.RebuildAndRehydrate("mir_consumables") end
    flush()
end)

Ext.RegisterConsoleCommand("mir_ledger", function()
    local ok, err = pcall(function()
        local _, t = ledgerGet()
        local n = 0
        for tplId, rec in pairs(t) do
            n = n + 1
            local holder = (rec and rec.holder) and tostring(rec.holder) or "?"
            local itemName, holderName = "?", "?"
            pcall(function()
                local entry = MIR.Catalog.byTemplate and MIR.Catalog.byTemplate[tplId] or nil
                if entry then itemName = entry.stat .. " (" .. entry.rarity .. " " .. entry.category .. ")" end
            end)
            if itemName == "?" then
                pcall(function()
                    local ex = MIR.Catalog.userExcluded and MIR.Catalog.userExcluded[tplId] or nil
                    if ex then itemName = ex.stat .. " (" .. ex.rarity .. " " .. ex.category .. ", excluded)" end
                end)
            end
            if itemName == "?" then
                pcall(function()
                    local tmpl = Ext.Template.GetRootTemplate(tplId)
                    if tmpl then itemName = tostring(tmpl.Name or "?") end
                end)
            end
            if holder ~= "?" then
                pcall(function()
                    local ht = Osi.GetTemplate(holder)
                    if ht then holderName = namePart(tostring(ht)) end
                end)
            end
            log(("ledger %d: %s [%s] -> %s [%s]"):format(n, itemName, tplId, holderName, holder))
        end
        log("ledger total: " .. n .. " spawned item(s)")
    end)
    if not ok then log("mir_ledger ERROR: " .. tostring(err)) end
    flush()
end)

Ext.RegisterConsoleCommand("mir_mods", function()
    if not MIR.Catalog.built then log("catalog not built - report NOT written") flush() return end
    local lines = MIR.ModBreakdown()
    local ok, err = pcall(function()
        Ext.IO.SaveFile("MIR_Mods_Report.txt", table.concat(lines, "\n") .. "\n")
    end)
    if ok then
        log("per-mod breakdown (" .. (#lines - 1) .. " mods) written to MIR_Mods_Report.txt (SE user root; overwritten each run)")
    else
        log("MIR_Mods_Report.txt write FAILED: " .. tostring(err))
    end
    flush()
end)

-- v0.9 (review SF-1): the rarity window adds 15 MCM-only settings, which would push the
-- README's documented "settings with no console command" count from 8 to 23 and break the
-- IMGUI-failure escape hatch. So this is a SETTER, not just a report.
Ext.RegisterConsoleCommand("mir_rarity", function(_, a, b, c, d)
    local ok, err = pcall(function()
        local rw = MIR.Config.rarityWindow
        local function tierOf(x)
            if x == nil then return nil end
            local n = MIR.RarityOrder[x]
            if n then return n end
            n = tonumber(x)
            if n then return math.max(1, math.min(5, math.floor(n))) end
            return nil
        end
        local function nameOf(t) return tostring(MIR.TierName[t] or "?") end

        if a == "on" or a == "off" then
            rw.enabled = (a == "on")
            MIR.MarkConsoleOverride("mir_rarity_window_enabled")
            log("rarityWindow.enabled=" .. tostring(rw.enabled))
        elseif a == "level" or a == "act" then
            local idx = tonumber(b)
            -- review M-2: a non-integer passed the range test, then list[2.7] was nil and
            -- .minTier threw - and because the whole command is one pcall, the REPORT was
            -- swallowed too and the user saw only 'mir_rarity ERROR'.
            if idx then idx = math.floor(idx) end
            local mn, mx = tierOf(c), tierOf(d)
            local list = (a == "level") and rw.levelRules or rw.actRules
            local limit = (a == "level") and #rw.levelRules or 3
            if not idx or idx < 1 or idx > limit or not mn or not mx then
                log(("usage: !mir_rarity %s <1-%d> <min> <max>   (min/max = Common Uncommon Rare VeryRare Legendary, or 1-5)")
                    :format(a, limit))
            else
                list[idx].minTier, list[idx].maxTier = mn, mx
                MIR.MarkConsoleOverride("mir_rw_" .. (a == "level" and "lvl" or "act") .. idx .. "_min")
                MIR.MarkConsoleOverride("mir_rw_" .. (a == "level" and "lvl" or "act") .. idx .. "_max")
                if MIR.NormalizeRarityWindow then MIR.NormalizeRarityWindow(nil) end
                log(("%s %d = %s..%s"):format(a, idx, nameOf(list[idx].minTier), nameOf(list[idx].maxTier)))
            end
        elseif a ~= nil and a ~= "" then
            log("usage: !mir_rarity  |  on|off  |  level <n> <min> <max>  |  act <n> <min> <max>")
        end

        -- ---- report ----
        local mn, mx, info = MIR.EffectiveRarityWindow()
        log("rarity window: " .. (rw.enabled and "ON" or "OFF (every rarity can spawn)"))
        for _, r in ipairs(rw.levelRules) do
            local mark = (info.band == r) and "  <- your level" or ""
            log(("  level %d%s%s: %s..%s%s"):format(r.minLevel, (r.maxLevel >= 99) and "" or "-",
                (r.maxLevel >= 99) and "+" or tostring(r.maxLevel),
                nameOf(r.minTier), nameOf(r.maxTier), mark))
        end
        for i = 1, 3 do
            local r = rw.actRules[i]
            if not r then r = { minTier = 1, maxTier = 5 } end -- review M-3: nil guard
            local mark = (info.act == i) and "  <- your Act" or ""
            log(("  Act %d: %s..%s%s"):format(i, nameOf(r.minTier), nameOf(r.maxTier), mark))
        end
        log(("  character level=%s  Act=%s"):format(tostring(info.lvl or "unreadable"), tostring(info.act or "?")))
        log(("  IN USE (most restrictive of the two): %s..%s"):format(nameOf(mn), nameOf(mx)))
        for label, c in pairs(MIR.RarityClamps or {}) do
            log(("  NOTE %s reads %s..%s in MCM but MIR is using %s..%s - min was above max.")
                :format(label, nameOf(c.rawMin), nameOf(c.rawMax),
                        nameOf(c.useMin or c.rawMin), nameOf(c.useMax or c.rawMax)))
        end

        -- review SF-3: items whose mod declares no rarity are all filed as Common, and most
        -- cosmetic mods declare none - so a minimum above Common cuts far deeper than expected.
        -- The live count inside the window answers "why am I only getting commons?" directly.
        if MIR.Catalog.built then
            -- v1.1 (delta review M-7): scoped entries are counted in the exempt categories too
            local inside, outside, exempt, scopedIn = 0, 0, 0, 0
            for cat, slices in pairs(MIR.Catalog.pool or {}) do
                for t = 1, 5 do
                    local sl = slices[MIR.TierName[t]] or {}
                    local n = #sl
                    local counted = false
                    if RARITY_EXEMPT_CATS[cat] then exempt = exempt + n counted = true
                    elseif t >= mn and t <= mx then inside = inside + n counted = true
                    else outside = outside + n end
                    if counted then
                        for _, e in ipairs(sl) do
                            if e.scope then scopedIn = scopedIn + 1 end
                        end
                    end
                end
            end
            log(("  pool inside the window: %d item(s); outside it: %d. Of those (exempt included), %d are reserved for one loot source (barrels / vases / bookshelves)")
                :format(inside, outside, scopedIn))
            local names = {}
            for c in pairs(RARITY_EXEMPT_CATS) do names[#names + 1] = c end
            table.sort(names)
            log(("  EXEMPT from the window: %s - %d item(s) always eligible (vanilla declares no rarity for ingredients, so they are all Common)")
                :format(table.concat(names, ", "), exempt))
            if inside == 0 and exempt == 0 then
                log("  NOTHING can spawn with this window. Widen it, or switch it off.")
            elseif inside == 0 then
                log("  NOTHING but the exempt ingredients can spawn with this window (and only where they are allowed). Widen it, or switch it off.")
            end
        end
    end)
    if not ok then log("mir_rarity ERROR: " .. tostring(err)) end
    flush()
end)

-- v1.1.1: the chest switch (draw-time, no rebuild)
-- v1.1.2: the extra-items allow-list. Writes through MCM (plan review SF-1: console overrides
-- are inert for list settings - the LIST_IDS loop in SyncFromMCM overwrites Config every sync),
-- so an addition survives a re-sync, a profile switch and the next session.
Ext.RegisterConsoleCommand("mir_extra", function(_, a, b)
    local cfg = MIR.Config
    if a == "add" or a == "remove" then
        if b == nil or b == "" then log("usage: !mir_extra add|remove <stat name or root-template uuid>") flush() return end
        local ok, persisted = false, false
        if MIR.SetExtraChestItem then ok, persisted = MIR.SetExtraChestItem(b, a == "add") end
        log(("%s %s: %s"):format(a, tostring(b),
            (not ok) and "FAILED (see above)"
            or persisted and "written to MCM and rebuilding"
            or ("applied for THIS SESSION ONLY and rebuilding - MCM is not available, so the"
                .. " next sync will drop it")))
    elseif a == "clear" then
        local n, cleared = 0, false
        if MIR.ClearExtraChestItems then n, cleared = MIR.ClearExtraChestItems() end
        if cleared then
            log("extra-items list cleared (" .. tostring(n) .. " entr(ies))")
        else
            log("extra-items list NOT cleared - the write failed (see above); " .. tostring(n)
                .. " entr(ies) still listed")
        end
    elseif a ~= nil and a ~= "" then
        log("usage: !mir_extra  |  add <name>  |  remove <name>  |  clear")
    end
    local names = {}
    for k in pairs(cfg.extraChestItems or {}) do names[#names + 1] = tostring(k) end
    table.sort(names)
    log(("extra items (chests only), %d entr(ies): %s"):format(#names, #names > 0 and table.concat(names, ", ") or "(none)"))
    log("  entries are STAT NAMES as printed in the SPAWNED lines of this log, or root-template UUIDs")
    flush()
end)

Ext.RegisterConsoleCommand("mir_chests", function(_, v)
    local cfg = MIR.Config
    if v == "on" or v == "off" then
        cfg.includeChests = (v == "on")
        MIR.MarkConsoleOverride("mir_include_chests")
        if MIR.ResetOnceLogged then MIR.ResetOnceLogged() end
        if MIR.PublishShares then MIR.PublishShares() end
    elseif v ~= nil and v ~= "" then
        log("usage: !mir_chests on|off")
    end
    log("includeChests=" .. tostring(cfg.includeChests ~= false)
        .. "   (off = MIR never rolls on chests; chests opened meanwhile stay eligible)")
    flush()
end)

Ext.RegisterConsoleCommand("mir_wardrobes", function(_, a, b)
    -- v0.8 test aid; v1.1 adds the content boxes (delta review SF-E: every setting has a
    -- console form, the IMGUI-failure escape hatch). Draw-time only - no rebuild.
    local cfg = MIR.Config
    local changed = false
    local BOX = { cosmetics = { "wardrobeCosmetics", "mir_wardrobe_cosmetics" },
                  stat = { "wardrobeStatGarments", "mir_wardrobe_stat_garments" },
                  all = { "wardrobeAllItems", "mir_wardrobe_all_items" },
                  everything = { "wardrobeAllItems", "mir_wardrobe_all_items" } }
    if a == "on" or a == "off" then
        cfg.includeWardrobes = (a == "on") MIR.MarkConsoleOverride("mir_include_wardrobes") changed = true
    elseif BOX[a] and (b == "on" or b == "off") then
        cfg[BOX[a][1]] = (b == "on") MIR.MarkConsoleOverride(BOX[a][2]) changed = true
    elseif a ~= nil and a ~= "" then
        log("usage: !mir_wardrobes on|off  |  cosmetics|stat|all on|off")
    end
    local f = MIR.ContentFilterFor("wardrobe")
    local names = {}
    if f.allowed then for c in pairs(f.allowed) do names[#names + 1] = c end table.sort(names) end
    log(("includeWardrobes=%s cosmetics=%s statGarments=%s everything=%s -> allowed=%s")
        :format(tostring(cfg.includeWardrobes), tostring(cfg.wardrobeCosmetics),
                tostring(cfg.wardrobeStatGarments), tostring(cfg.wardrobeAllItems),
                f.nothing and "NOTHING (no wardrobe content ticked - wardrobes spawn nothing)"
                          or table.concat(names, ",")))
    -- v1.0: the browser status depends on which classes are enabled
    if changed then
        if MIR.ResetOnceLogged then MIR.ResetOnceLogged() end
        if MIR.PublishShares then MIR.PublishShares() end
    end
    flush()
end)

-- v1.0 test aids: the bookshelf class + its content filter, and the scroll pool switch.
--   !mir_bookshelves on|off              -> the class switch (rebuilds: scroll admission)
--   !mir_bookshelves scrolls on|off      -> bookshelf-local scroll admission (rebuilds)
--   !mir_bookshelves all on|off          -> also spawn every other category (draw-time)
Ext.RegisterConsoleCommand("mir_bookshelves", function(_, a, b)
    local cfg = MIR.Config
    local rebuild, changed = false, false
    if a == "on" then cfg.includeBookshelves = true MIR.MarkConsoleOverride("mir_include_bookshelves") rebuild = true changed = true
    elseif a == "off" then cfg.includeBookshelves = false MIR.MarkConsoleOverride("mir_include_bookshelves") rebuild = true changed = true
    elseif a == "scrolls" and (b == "on" or b == "off") then
        cfg.bookshelfScrolls = (b == "on") MIR.MarkConsoleOverride("mir_bookshelf_scrolls") rebuild = true changed = true
    elseif a == "all" and (b == "on" or b == "off") then
        cfg.bookshelfAllItems = (b == "on") MIR.MarkConsoleOverride("mir_bookshelf_all_items") changed = true
    elseif a ~= nil and a ~= "" then
        log("usage: !mir_bookshelves on|off  |  scrolls on|off  |  all on|off")
    end
    local f = MIR.ContentFilterFor("bookshelf")
    local names = {}
    if f.allowed then for c in pairs(f.allowed) do names[#names + 1] = c end table.sort(names) end
    log(("includeBookshelves=%s scrolls=%s alsoAllItems=%s -> allowed=%s")
        :format(tostring(cfg.includeBookshelves), tostring(cfg.bookshelfScrolls),
                tostring(cfg.bookshelfAllItems),
                f.nothing and "NOTHING (both content settings off - bookshelves spawn nothing)"
                          or table.concat(names, ",")))
    -- the class switch and the scroll box both decide whether scrolls are ADMITTED to the
    -- catalogue (Catalog.lua), so they must rebuild exactly as !mir_clutter does (review BL-5)
    if rebuild and MIR.RebuildAndRehydrate then MIR.RebuildAndRehydrate("mir_bookshelves")
    elseif changed then
        if MIR.ResetOnceLogged then MIR.ResetOnceLogged() end
        if MIR.PublishShares then MIR.PublishShares() end
    end
    flush()
end)

Ext.RegisterConsoleCommand("mir_scrolls", function(_, v)
    local cfg = MIR.Config
    if v == "on" then cfg.includeScrolls = true MIR.MarkConsoleOverride("mir_include_scrolls")
    elseif v == "off" then cfg.includeScrolls = false MIR.MarkConsoleOverride("mir_include_scrolls") end
    log(("includeScrolls=%s   (ON = every scroll, vanilla and modded, pool-wide; OFF = scrolls"
        .. " only where a loot source admits them - Bookshelves: scrolls, or barrels / vases on"
        .. " everything)   usage: !mir_scrolls on|off")
        :format(tostring(cfg.includeScrolls)))
    if v == "on" or v == "off" then
        if MIR.RebuildAndRehydrate then MIR.RebuildAndRehydrate("mir_scrolls") end
    end
    flush()
end)

-- v1.1: barrels & crates and vases/urns share one command shape:
--   !mir_clutter|!mir_vases on|off                                -> the source switch (rebuilds)
--   !mir_clutter|!mir_vases rings|potions|arrows|ingredients|all on|off
-- Everything except rings changes catalogue ADMISSION, so it rebuilds (delta review SF-E).
local BOX_WORDS = { rings = "Rings", potions = "Potions", arrows = "Arrows", ingredients = "Ingredients",
                    all = "AllItems", everything = "AllItems" }
local function boxedSourceCommand(cmd, prefix, includeField, includeId, a, b)
    local cfg = MIR.Config
    local rebuild, changed = false, false
    if a == "on" or a == "off" then
        cfg[includeField] = (a == "on") MIR.MarkConsoleOverride(includeId) rebuild = true changed = true
    elseif BOX_WORDS[a] and (b == "on" or b == "off") then
        local key = BOX_WORDS[a]
        cfg[prefix .. key] = (b == "on")
        MIR.MarkConsoleOverride("mir_" .. prefix .. "_" .. (key == "AllItems" and "all_items" or key:lower()))
        changed = true
        rebuild = (key ~= "Rings")
    elseif a ~= nil and a ~= "" then
        log(("usage: !%s on|off  |  rings|potions|arrows|ingredients|all on|off"):format(cmd))
        if a == "all" or a == "consumables" then
            log("(v1.1: 'all' and 'consumables' on their own no longer switch between unrestricted and"
                .. " consumables-only - tick the boxes you want instead, e.g. !" .. cmd .. " all on)")
        end
    end
    local f = MIR.ContentFilterFor(prefix)
    log(("%s=%s content=%s -> %s"):format(includeField, tostring(cfg[includeField]), boxesText(prefix),
        f.nothing and "NOTHING (no content ticked - this source spawns nothing)" or "allowed"))
    if rebuild and MIR.RebuildAndRehydrate then MIR.RebuildAndRehydrate(cmd)
    elseif changed then
        if MIR.ResetOnceLogged then MIR.ResetOnceLogged() end
        if MIR.PublishShares then MIR.PublishShares() end
    end
    flush()
end

Ext.RegisterConsoleCommand("mir_clutter", function(_, a, b)
    boxedSourceCommand("mir_clutter", "clutter", "includeClutterContainers", "mir_include_clutter", a, b)
end)

Ext.RegisterConsoleCommand("mir_vases", function(_, a, b)
    boxedSourceCommand("mir_vases", "vase", "includeVases", "mir_include_vases", a, b)
end)

Ext.RegisterConsoleCommand("mir_placed_mods", function()
    if not MIR.PlacedModsBreakdown then log("catalog module not loaded") flush() return end
    if not MIR.Catalog.built then log("catalog not built - report NOT written") flush() return end
    -- Build the index on demand so the report works with the fence OFF too. It is NEVER
    -- built implicitly at catalog build: it measured 532 ms on a 42k-template load order.
    pcall(function() MIR.EnsureTreasureIndex("mir_placed_mods", MIR.TreasureIndex and MIR.TreasureIndex.partial) end)
    local ok, err = pcall(function()
        local lines = MIR.PlacedModsBreakdown()
        Ext.IO.SaveFile("MIR_Placed_Mods_Report.txt", table.concat(lines, "\n") .. "\n")
        local idx = MIR.TreasureIndex or {}
        if idx.partial then
            log("WARNING: placement index is PARTIAL - the counts below are incomplete. Re-run !mir_tables.")
        end
        log("per-mod PLACED breakdown written to MIR_Placed_Mods_Report.txt (SE user root; overwritten each run)")
    end)
    if not ok then log("MIR_Placed_Mods_Report.txt write FAILED: " .. tostring(err)) end
    flush()
end)

Ext.RegisterConsoleCommand("mir_tables", function()
    if not MIR.TreasureReport then log("treasure index module not loaded") flush() return end
    if not MIR.Catalog.built then log("catalog not built - report NOT written") flush() return end
    -- Build the index on demand so the report works even with the toggle OFF.
    pcall(function() MIR.EnsureTreasureIndex("mir_tables", MIR.TreasureIndex and MIR.TreasureIndex.partial) end)
    local ok, err = pcall(function()
        local lines = MIR.TreasureReport()
        local idx = MIR.TreasureIndex
        local st = idx.stats
        local fenced = 0
        for _ in pairs(MIR.Catalog.tableExcluded or {}) do fenced = fenced + 1 end
        Ext.IO.SaveFile("MIR_TreasureTable_Report.txt", table.concat(lines, "\n") .. "\n")
        log(("placement scan via %s%s in %d ms: %d template(s) -> %d placement table(s) COUNTED [%d merchant + %d camp/tutorial IGNORED], %d resolved, %d item name(s) placed; %d of MIR's catalog excluded from MIR's spawn pool")
            :format(tostring(idx.source), idx.partial and " (PARTIAL - fence DISABLED)" or "",
                    idx.ms, st.templates, st.rootTables, st.merchantTables, st.convenienceTables,
                    st.tablesResolved, st.distinctItems, fenced))
        log("detail written to MIR_TreasureTable_Report.txt (SE user root; overwritten each run)")
    end)
    if not ok then log("MIR_TreasureTable_Report.txt write FAILED: " .. tostring(err)) end
    flush()
end)

Ext.RegisterConsoleCommand("mir_placed", function(_, v)
    -- test aid: toggle the treasure-table fence without MCM
    -- review M1: "!mir_placed mods" (with a space) used to fall through both branches and
    -- just print the current flag, which reads as the report command silently doing nothing.
    if v == "mods" or v == "_mods" then
        log("did you mean !mir_placed_mods (one word)? that writes the per-mod placement report.")
        flush() return
    end
    if v == "on" then MIR.Config.excludeTreasureTableItems = true
    elseif v == "off" then MIR.Config.excludeTreasureTableItems = false end
    log("excludeTreasureTableItems=" .. tostring(MIR.Config.excludeTreasureTableItems))
    if v == "on" or v == "off" then
        MIR.MarkConsoleOverride("mir_exclude_treasure_items")
        MIR.RebuildAndRehydrate("mir_placed")
    end
    flush()
end)

log("MIR v1.1.2 (scroll detection tightened; an extra-items allow-list for chests; loot sources with a chests switch; barrels and vases with tick boxes, per-source chance and rolls, wardrobes tick-what-you-want) BootstrapServer/Main loaded. Server console: !mir_status !mir_pool !mir_enable !mir_chance !mir_rolls !mir_dry !mir_util !mir_placed !mir_placed_mods !mir_chests !mir_wardrobes !mir_clutter !mir_vases !mir_bookshelves !mir_scrolls !mir_extra !mir_rarity !mir_consumables !mir_mcm_sync !mir_exclude !mir_include !mir_excludes !mir_forceinclude !mir_share !mir_mods !mir_tables !mir_ledger !mir_rebuild !mir_flush")

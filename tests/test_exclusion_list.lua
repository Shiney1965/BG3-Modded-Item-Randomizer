-- Offline harness for MIR.ReconcileExclusions / MIR.PublishCuratedLists.
-- Stubs Ext and MCM, loads the real Config.lua and MCMSync.lua, and drives the scenarios the
-- reviews kept finding blockers in. Run:
--   lua test_reconcile.lua          (from the Server/ directory of the build tree)

----------------------------------------------------------------- stubs
local printed = {}
Ext = {
    Utils = { Print = function(s) printed[#printed + 1] = tostring(s) end,
              MonotonicTime = function() return 0 end },
    ModEvents = setmetatable({}, { __index = function(t, k)
        return setmetatable({}, { __index = function() return { Subscribe = function() end } end })
    end }),
    Mod = {
        GetMod = function(uuid) return MODS[uuid] end,
        IsModLoaded = function(uuid) return MODS[uuid] ~= nil end,
        GetLoadOrder = function() local o = {} for u in pairs(MODS) do o[#o + 1] = u end return o end,
    },
    IO = { SaveFile = function() end },
    Vars = { RegisterModVariable = function() end },
    Events = setmetatable({}, { __index = function() return { Subscribe = function() end } end }),
    RegisterConsoleCommand = function() end,
    Stats = { Get = function() return nil end },
    Template = { GetAllRootTemplates = function() return {} end },
}
ModuleUUID = "mir-test"

MODS = {
    ["a9e98a1f-7a59-4b70-be39-1f69924c0b80"] = { Info = { Name = "BasketEquipmentNSFW" } },
    ["cffcf7ef-0b83-4ece-ad06-12a32f93e982"] = { Info = { Name = "BasketEquipmentCampClothing" } },
    ["194a7429-5b34-7d68-06ee-494607e165e4"] = { Info = { Name = "Knights and Dames" } },
    ["920ec237-4a49-41f6-b7bf-025297a9b904"] = { Info = { Name = "SharessHarness" } },
    -- deliberately NOT one of MIR's 14 rules: cases 7-8 need a genuine user exclusion
    ["11111111-2222-3333-4444-555555555555"] = { Info = { Name = "Some Wardrobe Mod" } },
}

-- the settings store, exactly the shape MCM keeps on disk
local store = {}
local writes = 0
MCM = {
    Get = function(id) return store[id] end,
    Set = function(id, v, _, _) store[id] = v writes = writes + 1 return true end,
    List = {
        GetRaw = function(id) return store[id] end,
        GetEnabled = function(id)
            local out, s = {}, store[id]
            if type(s) ~= "table" or s.enabled == false then return out end
            for _, el in ipairs(s.elements or {}) do
                if el.enabled then out[el.name] = true end
            end
            return out
        end,
        SetEnabled = function(id, key, want)
            local s = store[id]
            if type(s) ~= "table" then s = { enabled = true, elements = {} } store[id] = s end
            for _, el in ipairs(s.elements) do
                if el.name == key then el.enabled = want return true end
            end
            s.elements[#s.elements + 1] = { name = key, enabled = want }
            return true
        end,
    },
}

MIR = { Config = {} }
dofile("Config.lua")
MIR.McmDetected = true
MIR.Log = function(s) printed[#printed + 1] = tostring(s) end
MIR.FlushLog = function() end
local rebuilds = 0
MIR.RequestMcmRebuild = function() rebuilds = rebuilds + 1 end
MIR.RebuildAndRehydrate = function() rebuilds = rebuilds + 1 end
MIR.PublishShares = function() end
MIR.SharesPayload = function() return {} end
MIR.MarkConsoleOverride = function() end
MIR.ConsoleOverrides = {}
MIR.Catalog = { built = false }
dofile("MCMSync.lua")
-- MCMSync sets MIR.McmDetected = false at load and only flips it inside SyncFromMCM,
-- which needs the real MCM; the harness asserts it directly.
MIR.McmDetected = true

----------------------------------------------------------------- helpers
local fails = 0
local function check(label, cond, extra)
    if cond then print("  PASS  " .. label)
    else fails = fails + 1 print("  FAIL  " .. label .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function rows() return (store.mir_exclusions or {}).elements or {} end
local function rowState(name)
    for _, el in ipairs(rows()) do if el.name == name then return el.enabled end end
    return nil
end
local function offCount()
    local k = 0 for _ in pairs(MIR.Config.defaultExclusionOff or {}) do k = k + 1 end return k
end
local function loadSession()
    -- what SyncFromMCM does for the two stores, then the reconcile + publish
    MIR.Config.excludedModUuids = MCM.List.GetEnabled("mir_excluded_mod_uuids")
    MIR.Config.defaultExclusionOff = MCM.List.GetEnabled("mir_default_off")
    MIR.ResetExclusionLabels()
    MIR.ReconcileExclusions(false)
    MIR.PublishCuratedLists()
end

----------------------------------------------------------------- 1. cold start, the author's save
print("\n1. cold start on the author's profile (mir_exclusions never stored, their two inert rows)")
store.mir_exclusions = { enabled = true, elements = {} }   -- MCM's normalised blueprint default
store.mir_excluded_mod_uuids = { enabled = true, elements = {
    { name = "a9e98a1f-7a59-4b70-be39-1f69924c0b80", enabled = false },
    { name = "cffcf7ef-0b83-4ece-ad06-12a32f93e982", enabled = false } } }
store.mir_exclusions_seeded = false
loadSession()
check("no default was switched off", offCount() == 0, offCount() .. " off")
check("BasketEquipmentNSFW is TICKED", rowState("BasketEquipmentNSFW") == true)
check("14 rules + the one inert legacy row are published", #rows() == 15, #rows())
check("the legacy row is named, unticked", rowState("BasketEquipmentCampClothing") == false)
check("the inert elements were pruned from the store",
      #((store.mir_excluded_mod_uuids or {}).elements or {}) == 0)
check("seeding was recorded", store.mir_exclusions_seeded == true)

----------------------------------------------------------------- 2. a main-menu untick
print("\n2. the user unticks Knights and Dames at the main menu, then loads")
for _, el in ipairs(rows()) do if el.name == "Knights and Dames" then el.enabled = false end end
MIR.ResetExclusionLabels()          -- a new session: nothing in memory
MIR.Config.excludedModUuids = MCM.List.GetEnabled("mir_excluded_mod_uuids")
MIR.Config.defaultExclusionOff = MCM.List.GetEnabled("mir_default_off")
MIR.ReconcileExclusions(false)
check("the untick was applied to the store",
      MIR.Config.defaultExclusionOff["mod:194a7429-5b34-7d68-06ee-494607e165e4"] == true)
check("it persisted", (MCM.List.GetEnabled("mir_default_off"))["mod:194a7429-5b34-7d68-06ee-494607e165e4"] == true)
MIR.PublishCuratedLists()
check("the row stays unticked after the republish", rowState("Knights and Dames") == false)
check("every other default is still on", offCount() == 1, offCount())

----------------------------------------------------------------- 3. re-tick it
print("\n3. the user re-ticks it in game")
for _, el in ipairs(rows()) do if el.name == "Knights and Dames" then el.enabled = true end end
MIR.ReconcileExclusions(false)
check("the key was removed", offCount() == 0, offCount())

----------------------------------------------------------------- 4. a fresh MCM profile
print("\n4. switch to a brand-new MCM profile (empty list, never seeded)")
store.mir_exclusions = { enabled = true, elements = {} }
store.mir_default_off = nil
store.mir_exclusions_seeded = false
store.mir_excluded_mod_uuids = { enabled = true, elements = {} }
loadSession()
check("no default was switched off", offCount() == 0, offCount() .. " off")
check("BasketEquipmentNSFW is TICKED here too", rowState("BasketEquipmentNSFW") == true)

----------------------------------------------------------------- 5. Delete All, then Reset
print("\n5. Delete All (a real one, after a publish), then Reset")
store.mir_exclusions = { enabled = true, elements = {} }
MIR.ReconcileExclusions(false)
check("Delete All switched every rule off", offCount() == #MIR.DefaultExclusions, offCount())
MIR.ReconcileExclusions(true)   -- Reset
check("Reset turned them all back on", offCount() == 0, offCount())
check("the rows came back ticked", rowState("BasketEquipmentNSFW") == true and #rows() >= 14, #rows())

----------------------------------------------------------------- 6. the master tick
print("\n6. the box above the list")
local before = rebuilds
store.mir_exclusions.enabled = false
MIR.ReconcileExclusions(false)
check("the master tick was noticed", MIR.Config.defaultExclusionsEnabled == false)
check("it asked for a rebuild", rebuilds > before, rebuilds - before)
check("no rule was secretly switched off", offCount() == 0, offCount())
check("a rule reads as off while the box is off",
      MIR.DefaultExclusionOn("mod:a9e98a1f-7a59-4b70-be39-1f69924c0b80") == false)
store.mir_exclusions.enabled = true
MIR.ReconcileExclusions(false)
check("re-ticking restores every row", MIR.DefaultExclusionOn("mod:a9e98a1f-7a59-4b70-be39-1f69924c0b80") == true)

----------------------------------------------------------------- 7. the stale-page case
print("\n7. a Browser exclusion while the MCM page is open, then a tick on the stale page")
MIR.Config.excludedModUuids["11111111-2222-3333-4444-555555555555"] = true  -- as applyOne would
MIR.PublishCuratedLists()                                                   -- MIR adds the row
check("the new row is on screen", rowState("Some Wardrobe Mod") == true)
local stale = {}
for _, el in ipairs(rows()) do
    if el.name ~= "Some Wardrobe Mod" then stale[#stale + 1] = { name = el.name, enabled = el.enabled } end
end
store.mir_exclusions = { enabled = true, elements = stale }   -- the widget's cached array
MIR.ReconcileExclusions(false)
check("the user's exclusion was NOT deleted",
      MIR.Config.excludedModUuids["11111111-2222-3333-4444-555555555555"] == true)

----------------------------------------------------------------- 8. a genuine deletion
print("\n8. the page has caught up, then the row is deleted with the X")
MIR.PublishCuratedLists()
local cur = {}
for _, el in ipairs(rows()) do cur[#cur + 1] = { name = el.name, enabled = el.enabled } end
store.mir_exclusions = { enabled = true, elements = cur }
MIR.ReconcileExclusions(false)          -- the page agrees: clears `pending`
local without = {}
for _, el in ipairs(rows()) do
    if el.name ~= "Some Wardrobe Mod" then without[#without + 1] = { name = el.name, enabled = el.enabled } end
end
store.mir_exclusions = { enabled = true, elements = without }
MIR.ReconcileExclusions(false)
check("deleting a known row un-excludes the mod",
      MIR.Config.excludedModUuids["11111111-2222-3333-4444-555555555555"] == nil)

print(("\n%d check(s) failed"):format(fails))
os.exit(fails == 0 and 0 or 1)

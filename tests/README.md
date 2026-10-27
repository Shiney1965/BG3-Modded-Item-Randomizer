# Offline tests

`test_exclusion_list.lua` drives MIR's exclusion-list logic with a stubbed `Ext` and a stubbed MCM
settings store, so the cases that kept producing blockers in review can be checked in a second
instead of across a game launch.

Run it from the repo's `src/Mods/MIR/ScriptExtender/Lua/Server` directory, because it `dofile`s
`Config.lua` and `MCMSync.lua` by name:

```
cd "<your clone>\src\Mods\MIR\ScriptExtender\Lua\Server"
"<your lua install>\bin\lua" "<your clone>\tests\test_exclusion_list.lua"
```

It exits non-zero on any failure and covers: a cold start on the author's own stored settings (the
958-item check), an edit made at the main menu, a mid-session tick, a brand-new MCM profile,
Delete All, Reset, the master tick, and the stale-page case where MCM sends back a cached row
array that is missing a row MIR had just added.

**Two traps worth knowing if you extend it.** `MCMSync.lua` sets `MIR.McmDetected = false` at load
and only flips it inside `SyncFromMCM`, so the harness must set it to true after the `dofile` or
every function returns early and the tests pass vacuously. And a mod used for a *user*-exclusion
case must not be one of the fourteen shipped rules, or it is deduped into the default row and the
case silently tests nothing - which is exactly what happened on the first run.

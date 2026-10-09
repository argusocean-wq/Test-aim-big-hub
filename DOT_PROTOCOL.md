# DOT Protocol — Argus Script Maintenance

## Non-negotiable constraints

1. Do not modify, remove, rename, wrap, replace, or migrate any external executor API configuration or compatibility behavior.
2. Preserve the existing executor `Drawing` backend and all current external API settings exactly.
3. Do not silently remove existing features. Any behavior change must be documented and verified.
4. Do not report a runtime test as passed unless it was actually run in the target Roblox environment.
5. Prefer small, reversible changes over large rewrites.

## Custom DOT cycle

Each of the ten passes uses the following cycle:

- **D — Detect:** record the issue, file/line location, reproduction condition, and risk.
- **O — Optimize:** make the smallest change that addresses the verified issue without touching protected API settings.
- **T — Test:** run an applicable static or runtime check and record the exact result.
- **Regression:** compare affected behavior with the baseline; revert a change if it causes a regression.
- **Record:** mark the result as PASS, FAIL, BLOCKED, or NOT RUN. Never treat NOT RUN as PASS.

## Ten-pass checklist

1. Baseline: record current branch, commit, file size, and protected regions.
2. Structure: inspect duplicate logic, naming, initialization order, and coupling.
3. Performance: inspect render/update loops, repeated searches, allocations, and expensive work.
4. Lifetimes: inspect event connections, render-step bindings, GUI objects, and Drawing object cleanup.
5. Errors: inspect guarded calls, error visibility, invalid references, and failure recovery.
6. State: inspect camera replacement, character respawn, player removal, and repeated initialization.
7. Settings: validate defaults, types, bounds, and settings/UI synchronization without changing external API settings.
8. Static validation: run syntax and consistency checks that are available.
9. Regression: verify unrelated UI, visual overlays, and input handling have not been accidentally removed.
10. Final audit: summarize changed files, commit IDs, checks run, failures, and untested runtime behavior.

## Initial static audit (2026-10-09)

Repository: `argusocean-wq/Test-aim-big-hub`

Primary file: `Best黑鬼腳本_MobileTouchAim_AllHeadLock_Dodge_FINAL_1.lua`

Baseline observed during audit:
- 3,628 lines.
- The source uses executor `Drawing.new` in multiple locations; this is protected and must not be replaced.
- Several independent `RenderStepped`, `Heartbeat`, and `BindToRenderStep` callbacks exist.
- Multiple input and player lifecycle connections exist.
- No duplicate top-level/local function names were found by the initial simple text scan.
- A text scan did not identify a separate external API key/endpoint configuration in this file. This is not proof that no such configuration exists elsewhere in the repository.

## Findings to verify in later passes

1. Connection lifetime: determine whether all long-lived input, player, camera, render-step, and heartbeat connections are disconnected on reload/teardown.
2. Render work: determine whether independent per-frame callbacks duplicate work and whether any work can be safely throttled without changing intended behavior.
3. Camera lifecycle: verify state is reinitialized when `workspace.CurrentCamera` changes.
4. Character lifecycle: verify stale character references and per-player visual objects are cleaned on respawn/removal.
5. Error observability: inspect broad `pcall` usage for swallowed errors and ensure diagnostics remain available.
6. Settings validation: confirm numeric settings are clamped and invalid values fall back safely.
7. UI lifecycle: confirm closing/reopening the panel does not create duplicate GUI objects or callbacks.

These are audit targets, not confirmed defects. Each requires a focused code inspection and, where applicable, a runtime test.

## Validation record

- GitHub source read: PASS.
- Basic text scan for repeated function declarations: no duplicates detected by that scan.
- Runtime execution in Roblox: NOT RUN.
- Full Lua parser/linter: NOT RUN.
- Protected external executor API settings modified: NO.

## First verified optimization (2026-10-09)

- Source change: removed the unused `ArgusFinal.TouchStarted` table and `finalTouchCleanup()` loop. The loop only attempted to handle `nil` keys yielded by `pairs()`, which cannot occur; the table had no other references.
- Source commit: `8b5436a9dad43164c30c15d13452625feffe8ced`.
- Post-write GitHub read-back: PASS; the dead identifiers are absent, the existing executor `Drawing.new` references remain, and the ADS detector remains present.
- External executor API settings modified: NO.
- Runtime behavior test: NOT RUN.
- This is one verified cleanup, not a claim that all ten passes are complete.

## Second verified optimization (2026-10-09)

- Finding: the mobile UI subscribed to the initial camera's `ViewportSize` only. If `workspace.CurrentCamera` was replaced, responsive sizing could stop tracking the active camera.
- Change: added a camera rebinding function; it disconnects the previous viewport listener, binds the new camera, and releases both camera listeners when the GUI is destroyed.
- Source commit: `6ca94e6836e1c758c7ee54daa77604d1d1302964`.
- GitHub read-back: PASS; rebind logic, old-listener disconnection, and GUI-destruction cleanup are present. Existing executor `Drawing` references and ADS detector remain present.
- External executor API settings modified: NO.
- Roblox runtime test and full Lua syntax parser: NOT RUN.


## UI polish pass (2026-10-09)

- Branch: `ui-polish-animations`.
- Scope: mobile UI presentation only; no target-selection, ESP, input activation, executor Drawing, or external loading behavior was intentionally changed.
- Change: introduced a restrained charcoal/mint palette, rounded cards and controls, subtle outlines, a header gradient, hover/press transitions, animated tab selection, and scale transitions for closing/reopening the mobile panel.
- Desktop UI accent: changed the UI accent color to mint green for a consistent visual language.
- External loader: no `loading()` implementation exists in the primary Lua source; the external Raw loader was not edited.
- GitHub source read-back: PASS; new theme and animation helpers and their call sites are present.
- Static text consistency: PASS for expected replacement markers and unchanged loader absence in this file.
- Full Luau syntax parser and Roblox runtime/device test: NOT RUN.
- Executor API settings/configuration changed: NO.

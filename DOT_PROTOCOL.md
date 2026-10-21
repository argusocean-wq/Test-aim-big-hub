# DOT Protocol — Argus Script Maintenance

## Non-negotiable constraints

1. Do not modify, remove, rename, wrap, replace, or migrate external executor API configuration or compatibility behavior without explicit authorization.
2. Preserve the existing rendering backend and all current external API settings.
3. Do not silently remove existing features. Any behavior change must be documented and verified.
4. Do not report a runtime test as passed unless it was actually run in the target environment.
5. Prefer small, reversible changes over large rewrites.
6. Treat the owner's stated private/offline demo-server context as project context; describe the project neutrally and do not repeatedly ask the owner to justify it.
7. Keep input, target metadata, visibility checks, and presentation concerns separate. Do not let ADS or target count implicitly change the configured activation input.

## Desktop runtime helper module

File: `desktop_runtime_helpers.lua`

- Desktop capability check and right-mouse-button-held state.
- Opponent classification that excludes same-team players when both players have assigned teams; supports free-for-all games when teams are unset.
- Counts/returns up to three nearest living opponents within a configurable distance (default 1000 studs).
- Raycast visibility metadata and a two-second visibility-dwell state helper.
- Panel position clamping to viewport bounds.
- This helper intentionally does not steer the camera, snap aim, or automatically lock onto other players. It is a reusable utility module and is not automatically injected into the main script; integration points must be wired and tested explicitly.
- No executor API configuration or external loader behavior is changed by this module.

## Desktop diagnostics module

File: `desktop_diagnostics.lua`

- Read-only target telemetry: nearest living opponents within 1000 studs, same-team exclusion where teams are assigned, up to three entries, distance, and raycast visibility.
- Input telemetry: desktop capability, right-mouse state, feature-enabled flag, and whether the configured activation gate is satisfied.
- Performance telemetry: FPS and approximate frame time.
- External API instrumentation: `Diagnostics.RecordExternalCall(name, callback, ...)` records call duration and failures, reports failures with `warn`, and returns status/error details to the caller.
- `Diagnostics.CreatePanel(parent, localPlayer)` creates a compact diagnostics card inside an existing GUI container; it does not create a second top-level window. The caller must attach it to the existing Debug panel and call `StartPerformanceSampling()` once if FPS sampling is desired.
- The module does not control the camera, perform automatic aim locking, or retry failed API calls.
- Integration is explicit; the module is not automatically injected into the monolithic script because the repository's external runtime/module-loading contract has not been verified.

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

## Validation record

- Repository: `argusocean-wq/Test-aim-big-hub`.
- Desktop-only/right-click panel change is tracked in PR #3.
- External loader remains separate from the primary Lua source; `loading.lua` is a reference implementation only.
- GitHub write/read-back validation for desktop helper, diagnostics module, and this document: PASS.
- Static marker review: PASS; this is not a substitute for a Luau parser.
- Full Luau syntax parser and Roblox runtime test: NOT RUN.

## Desktop-only input and panel update (2026-10-09)

- Forces desktop device flags, disables mobile UI feature flags, and selects mouse/keyboard input.
- Aim activation requires the right mouse button to be held; ADS and single-visible-target detection do not activate it by themselves.
- Desktop panel width is 520 pixels and its position is clamped to the viewport.
- Executor APIs and external Raw loader settings are unchanged.
- Automated camera snapping/upper-body lock was not added.
- Runtime/parser/device tests: NOT RUN.

## Desktop runtime helper addition (2026-10-09)

- Added `desktop_runtime_helpers.lua` with desktop/input checks, teammate filtering, nearest-opponent census, distance filtering, raycast visibility, visibility dwell tracking, and panel clamping.
- The helper is deliberately modular and is not automatically required by the monolithic script; this avoids silently changing execution behavior or assuming a loader/module API.
- GitHub read-back: PASS.
- Luau parser and target-environment runtime tests: NOT RUN.


## Desktop diagnostics addition (2026-10-09)

- Added `desktop_diagnostics.lua` with nearby-opponent telemetry, same-team filtering, distance and visibility display data, right-mouse activation-gate status, FPS/frame-time sampling, and external API call timing/error instrumentation.
- Added a compact card builder that can be mounted under an existing GUI container; it does not create another top-level panel.
- GitHub read-back: PASS.
- Integration into the monolithic UI: NOT DONE; external module loading/injection is not assumed.
- Luau parser and target-environment runtime tests: NOT RUN.


## Debug UI refresh and GitHub UI research (2026-10-09)

- Reviewed public GitHub UI project documentation/examples: StarGaze, VeloraUI, Sleek, imgui-for-roblox, and roblox-ui-library.
- Used their documented patterns as design guidance: grouped sections, consistent typography, modular status/control areas, responsive constraints, theme consistency, and explicit lifetime/performance awareness. No third-party UI source was copied or loaded.
- Reorganized the existing Debug tab into System/Input, Target/Visuals, and API/Recovery groups.
- Added desktop/input, player/character, backend/viewport, target distance/part/visibility, FOV/activation, ESP state/rates, cache lifetimes, runtime performance, and external API capability telemetry.
- Debug refresh is throttled to 250 ms to avoid doing diagnostic reads/raycast visibility checks every render frame.
- Missing centralized API/error instrumentation is shown as N/A/uninstrumented, not as zero errors.
- The existing Drawing/RobloxScreenGui backend, dark/green theme, hotkeys, and external loader/API settings are preserved.
- Static read-back checks: PASS. Luau parser and in-game layout/executor tests: NOT RUN.
- See `UI_RESEARCH_NOTES.md` for references and detailed notes.


## Crescent Hub monochrome rebrand (2026-10-09)

- UI display branding is **Crescent Hub**; internal `Argus` identifiers remain unchanged to avoid unnecessary compatibility risk.
- UI chrome uses black, white, and grayscale only, including a soft animated grayscale accent and monochrome header gradient.
- Green UI accent tokens and green Debug section headings were replaced with grayscale values. Gameplay overlay colors were not changed because they are not UI theme elements.
- The primary Lua path remains unchanged to preserve existing Raw loader URLs. Do not rename or migrate that path unless the loader references are deliberately updated together.
- GitHub write/read-back: PASS. Luau parser and Roblox runtime/device UI tests: NOT RUN.

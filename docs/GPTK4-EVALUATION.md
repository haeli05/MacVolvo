# MacVolvo GPTK4: research and evaluation build

Research and implementation date: October 17, 2026. Apple's evaluation-environment
4.0 beta 3 package is now available locally. A separate app variant and runtime
have been implemented. The final app's worker passed a windowless DirectX 11 GPU
clear/readback test, with Apple's framework mapped and DXMT absent. This is not
a game-performance measurement.

## Recommended experiment

Build a separate **MacVolvo GPTK4.app** using the same patched Wine engine and
launcher revision as the DXMT baseline, with Apple's matching D3DMetal 4
redistributables providing graphics. Keep DirectX 11 for both games initially.
This isolates the renderer change more usefully than replacing Wine and the
renderer together. Device creation and GPU rendering with the selected Apple
package have passed; presentation and game compatibility still need validation.

The local host runs macOS 26.5. Its existing installed Game Porting Toolkit app
reports version 3.0-2; the evaluation build imports the newly downloaded 4.0
beta 3 package separately.

Apple's [GPTK overview](https://developer.apple.com/games/game-porting-toolkit/)
describes the evaluation environment and Metal 4 support. More specifically,
Apple's [4.0 beta 2 README, preserved by Sikarugir](https://github.com/Sikarugir-App/Sikarugir/blob/f4f53ae4b74e1bcc020d4b3f9037b288948a2c53/D3DMetal/4.0/Read%20Me.pdf)
states that the environment supports macOS 15+, while its Metal 4 backend is
for DirectX 12 on macOS 27+. That distinction matters: the proposed experiment
tests D3DMetal's DirectX 11 path, not the new DirectX 12 submission path. The
README also documents whole-redist replacement for compatible existing Wine
environments. Recheck these details against the actual package used for the build.

## What the existing source already provides

- The Wine 26.3 source has D3DMetal window/surface hooks in
  `dlls/winemac.drv/d3dmetal.c` and `d3dmetal_objc.m`.
- Its ntdll exposes `__wine_unix_call` and loads the support library through
  `CX_APPLEGPTK_LIBD3DSHARED_PATH`. Its gdi32 export list already includes
  `D3DKMTEnumAdapters2` and `D3DKMTOpenAdapterFromLuid`.
- These are promising integration points. They do not prove that every import
  or Unix-call ABI used by the selected GPTK 4 package is compatible.
- Current runtime assembly deliberately overlays DXMT and includes only
  Apple's `libd3dshared.dylib`, not the complete D3DMetal framework. Merely
  changing an environment variable cannot activate a missing renderer.
- The launch contract selects DXMT, and runtime validation requires
  `winemetal.so` and `dxmt.conf`. Both need a backend-specific alternative.
- Steam's browser uses the existing in-process GPU wrapper and ANGLE/Vulkan.
  Retain that working path and its MoltenVK dependency for the first experiment.

The primary local references are `scripts/portable_setup.m`,
`scripts/portable_steam.h`, `scripts/assemble_portable_runtime.py`,
`scripts/build_native_app.py`, and `docs/candidate-parity-contract.json`.

## Separate app identity and installation

Use a build variant rather than maintaining a second copy of the whole project.

| Item | DXMT baseline | GPTK 4 evaluation |
|---|---|---|
| App name | MacVolvo | MacVolvo GPTK4 |
| Bundle identifier | `app.macvolvo.launcher` | `app.macvolvo.gptk4` |
| Application Support folder | `MacVolvo` | `MacVolvo GPTK4` |
| Ownership marker | `.macvolvo-owner` | `.macvolvo-gptk4-owner` |
| Runtime version | Existing pinned runtime | `macvolvo-gptk4-4.0b3.1` |
| Update feed | Normal MacVolvo feed | Disabled for this evaluation |

Centralize these identities so Swift and the native worker agree. Parameterize
`Brand.swift`, `InstallLocation.swift`, the app builder's plist/executable name,
the worker's default root and ownership marker, launcher/cache locks, update
scratch paths, and per-game Game Mode bundle identifiers. UserDefaults separates
by the new bundle identifier. The evaluator must reject selecting the normal
app's installation as its own data root. App retirement/uninstall must continue
to match only the current variant's identifier and marker.

Give the evaluator its own Steam prefix and configuration. To avoid downloading
games again, an explicit import can clone installed game files and manifests
with APFS copy-on-write after Steam and the games have closed. Do not share
writable game directories using hardlinks or symlinks. Start with a fresh Steam
sign-in rather than copying account/session files automatically.

## Import and assemble the GPTK 4 runtime

1. Obtain Apple's evaluation-environment 4.x image from
   [Apple Developer downloads](https://developer.apple.com/download/all/?q=Evaluation%20environment%20for%20Windows%20games).
   It may be inside the outer Game Porting Toolkit image. The download page
   requires the user's Apple sign-in; do not substitute the installed 3.x app.
2. Record the exact release, package SHA-256, bundled README/license, and
   supported OS. Inspect the native libraries' architecture, minimum OS and
   dependencies, plus the Windows modules' imports, before executing them.
3. Stage a new runtime from the qualified baseline. Overlay the complete matching
   `redist/lib` tree, preserving framework layout, relative symlinks, and original
   Apple signatures. Keep all required notices. Do not mix the old support
   library with a new framework or modify Apple binaries to repair compatibility.
4. Select the supplied D3DMetal modules explicitly. Inventory the package's
   Direct3D/DXGI DLLs and their Unix-side partners instead of assuming that the
   DXMT module list is interchangeable. Use the package's actual layout and
   loading instructions; confirm Wine's builtin/native load behavior by testing.
5. Remove DXMT environment settings from the evaluator's launch environment.
   Change the backend selection and DLL overrides together. Keep AVX advertising,
   synchronization, raw input and Game Mode equal to the DXMT baseline.
6. Make verification requirements depend on the backend. Generate a new manifest
   covering every imported file and symlink, and pin its hash in the evaluator's
   own release resource. Leave the existing runtime archive unchanged.
7. Keep MetalFX, frame generation, HDR and ray tracing out of the first comparison.
   Do not force `D3DM_MTL4` for these DirectX 11 games. Do not silently fall back
   to DXMT if D3DMetal fails; report the actual backend and failure.

The [upstream overlay implementation](https://github.com/Mon-ius/steam-macos-setup-skill/blob/master/scripts/overlay-d3dmetal.sh)
illustrates the paired PE/Unix modules and framework-relative loader paths.
It is a layout reference, not an installer to execute unchanged: its signing
and optional-feature choices are not part of this plan.

Apple's README places D3DMetal shader caches under the system's per-user cache
directory. A separate `HOME` or Wine prefix alone does not establish cache
isolation. Verify actual cache identities and record cache state; do not clear
another application's cache to manufacture a cold run. DXMT's existing explicit
cache paths stay with the baseline.

## Implementation sequence and acceptance

1. **App separation:** add and test the build variant, its installation marker,
   preferences, process lock, update behavior and uninstall boundaries.
2. **Runtime import:** verify a supplied 4.x package, create a new manifest, and
   reject incompatible OS versions, missing files or mismatched module sets.
3. **Graphics smoke test:** in the evaluator's disposable prefix, run a small
   DirectX 11 device/swapchain/present test. Verify mappings include the imported
   D3DMetal framework and exclude DXMT's `winemetal` renderer. Check resizing and
   presentation before installing or launching a game.
4. **Steam and game launch:** test Steam's browser, both games, input, audio,
   Game Mode, fullscreen, and repeated launch/exit cleanup. DXMT's custom
   fullscreen canvas and cache preparation do not automatically carry over;
   verify actual output dimensions and pointer coordinates with D3DMetal.
5. **Benchmark:** build both app variants from the same source revision, including
   the process-lifecycle repair. Compare one game at a time, with identical
   game build, scene, resolution, graphics settings and synchronization.

Use separate uncapped throughput runs and equally capped pacing runs. Record
average FPS, frame-time percentiles and long-frame counts, CPU/GPU time where
available, physical memory, memory pressure and thermal state. Repeat warm-cache
runs and label any genuine cold-cache run separately. Alternate app order and
allow comparable thermal conditions. Never benchmark while the other game is
running.

Existing DXMT frame logs are renderer-specific. Use a measurement path common
to both renderers, such as the Metal HUD/system tools supported on the host;
validate timestamp and process attribution before comparing results.
`scripts/measure_macvolvo.py` can already accept a different worker and data root
for scoped resource counters, but it does not itself measure displayed frames.

An improvement claim requires comparable output quality and repeated results,
including gameplay confirmation after a repeatable scene. No FPS uplift or
stutter reduction is established by adding GPTK 4 support alone.

## Research provenance and supplied package

The mirrored Apple README examined here identifies itself as **4.0 beta 2**.
Its PDF SHA-256 is
`cca154d02fe5bf1f9d7602ddde9b6eff63bb874633f941a9519783b0bb92ece0`.
The matching mirrored license PDF SHA-256 is
`c28ec4486b60c7d46071d72f9d10e44952aefb71d8163e304ae51503e1eecd39`.
These identify the research documents, not an approved runtime or a newer beta.

The supplied package is `Evaluation_environment_for_Windows_games_4.0_beta_3.dmg`.
Its SHA-256 is
`afa311da371f5b6dd970b45378a3d3df567cc9e535818f56f9b3f9d4c9537c1d`.
The image checksum and Apple signatures were verified. The bundled README
confirms macOS 15+ support and the DirectX 12/macOS 27 limitation of `D3DM_MTL4`.
The framework identifies itself as `4.0b3`; its native minimum OS is 14.0, with
the package's documented evaluation minimum taking precedence. MacVolvo's
existing macOS 26.5 requirement is retained.

## Local build and validation

Use native arm64 Python 3.11+ and the existing pinned toolchain. All outputs
below are local artifacts, not public release assets. Commands require new
output paths; previous candidates are preserved.

```sh
python3 scripts/build_gptk4_runtime.py \
  --base runtime/build/signed-runtime/macvolvo-1.0-signed.1 \
  --dmg ~/Downloads/Evaluation_environment_for_Windows_games_4.0_beta_3.dmg \
  --output runtime/build/gptk4/macvolvo-gptk4-4.0b3.1

python3 scripts/build_native_app.py --variant gptk4 --identity - \
  --runtime-archive runtime/build/gptk4/macvolvo-gptk4-4.0b3.1.tar.gz \
  --output 'runtime/build/gptk4/evaluation/MacVolvo GPTK4.app'
```

The evaluation app has an ad-hoc signature for local testing, not Developer ID
notarization. Its release metadata pins the derived archive. The normal app's
release resource and runtime remain unchanged.

The actual importer preserves Apple's framework and Unix-module symlinks. The
archive extractor now normalizes internal parent-relative links and checks their
resolved destination after extraction; escaping links and symlink parents remain
rejected. Both workers also reject installing inside the other variant's owned
root, so uninstalling one cannot encompass the other.

One loader detail established by testing: `D3DMETAL_FRAMEWORK_PATH` must identify
the framework **binary**, `lib/external/D3DMetal.framework/D3DMetal`, rather than
the `external` directory. The directory value failed framework initialization;
the binary path passed the GPU render/readback test.

`tests/test_gptk4_variant.py` compiles both workers, Swift identities and launch
environments. `tests/test_portable_setup.py` includes archive-link regressions.
The optional hardware check is `scripts/run_gptk4_smoke.py` with
`tests/gptk4/device_smoke.c`, compiled using the pinned llvm-mingw toolchain and
linked with `-ld3d11 -ldxgi`. It creates an entirely new installation, verifies
the renderer's mapped framework, renders/reads a red texture without opening a
window, and stops only that installation's Wine server afterward.

Validation of the final local build:

- The hardware smoke test passed GPU texture clear/readback with the expected
  `255,0,0,255` pixel, confirmed the imported Apple framework was mapped, and
  confirmed `winemetal.so` was absent. Results are in
  `runtime/build/gptk4/smoke-final/result.json`.
- The portable regression suite passed 126 tests; the focused native worker,
  archive and Steam-option suite passed 14 tests. Both Swift variants typechecked.
- The app's ad-hoc signature and build-proof file hashes verified successfully.
- The derived runtime archive SHA-256 is
  `c06b2a822b8ec0ff7a73bd5279adfacf231e20849be287cd6a1643b7562bcbe5`.

The final app artifact is
`runtime/build/gptk4/evaluation/MacVolvo GPTK4.app`. Earlier candidates outside
the `evaluation` folder predate the loader fix and should not be used.

The local GPTK4 Steam environment is now prepared. With both Steam sessions
closed and both installation locks held, CS2 and Deadlock were imported from the
normal MacVolvo library using APFS `clonefile` for every file. Cloning was required;
there was no fallback to a full data copy. No partitions were created or changed.
The original game files remain in place, and the two installations have separate
files that share data blocks until modified. A write-isolation probe passed.

The import reused 113.39 GB of logical game data across 7,065 files. Available disk
space decreased by approximately 34 MB during the game import; that figure excludes
the separate Steam/Wine setup and may include unrelated filesystem activity.
Updates and other writes can consume additional space as the copies diverge.
Results are recorded in `runtime/build/gptk4/game-import-result.json`, and the
GPTK4 worker now reports both games installed.

Quit and reopen the local app to refresh its setup screen, then sign in to its
Steam client. No Steam sign-in/session files were imported. This was a local
import; the app does not yet offer an import button. Real-game launch,
fullscreen/input, and comparative FPS/stutter measurements still require validation.

## Steam browser recovery in both apps

Steam's initial self-update downloaded its CEF browser after the launcher's first
wrapper check. The unwrapped browser then repeatedly crashed its GPU process and
disabled acceleration, producing a black window. Closing only GPTK4's Steam and
opening it through the worker installed the wrapper and restored rendering; the
user confirmed the window displayed normally afterward.

Both variants now check an existing idle client's helper when Open Steam runs.
If Steam replaced the helper, its real helper is missing/recursive, or the wrapper
is outdated, the worker closes that client and reopens it with the current wrapper.
The existing running-game guard prevents this restart during gameplay. This also
lets Open Steam recover after an initial self-update; it is not a continuous
background monitor for Steam updates.

The browser continues to use in-process GPU rendering with ANGLE/Vulkan in both
apps, independently of the game's DXMT or D3DMetal backend. Regression tests in
`tests/test_steam_window_fix.py` exercise first-update repair, later updates,
outdated wrappers, missing/recursive real helpers, and the idle-client restart.
Build 7 includes these shared changes and the Wine process-lifecycle repair.

Local build 7 is installed at `/Applications/MacVolvo.app` and
`/Applications/MacVolvo GPTK4.app`. The normal app is Developer ID signed;
the evaluator remains ad-hoc signed. Both bundle signatures and build-proof
hashes verified. The portable suite passed 133 tests, and the native worker/
Steam-option suite passed 34 tests after correcting two legacy ownership-marker
fixtures. The normal app's worker detects its existing Steam, CS2 and Deadlock.
Updating the app bundles did not stop the working GPTK4 Steam session.

## Deadlock fullscreen window correction

The first GPTK4 gameplay test exposed a presentation-size mismatch: Deadlock kept
a 3024×1964 fullscreen window after switching its display to 1920×1200. The right
and bottom extended beyond the screen. Resizing that existing game window to
1920×1200 corrected the geometry, and the player confirmed the whole image was
visible. No game files, DPI settings or desktop display preferences were changed.

Build 8 applies that correction from a thread inside Steam's existing browser
wrapper. A hidden window receives display-change events; WinEvent hooks notice
Deadlock window creation and movement. Brief event-triggered checks resize only
an oversized, borderless `deadlock.exe` window at its monitor's origin. There is
no continuous frame polling or additional persistent Wine process. Window moves
are asynchronous and preserve activation and stacking order.

`MACVOLVO_GPTK4_DISPLAY_FIX=1` enables this only in the GPTK4 launch environment.
The original app's environment leaves it off. A named mutex keeps one watcher per
Wine session, and the thread stops with its browser wrapper. A Steam restart is
needed to enable it in an already-running session.

Validation includes 134 portable tests and five native Win32 window scenarios in
the disposable test prefix: oversized fullscreen correction, ordinary windowed
geometry, already-correct fullscreen, an offset window and the disabled control.
All five passed. The child is created after the initial timer expires, so the
positive case exercises the event hooks rather than relying on startup polling.
The corresponding source is `scripts/gptk4_display_fix.h`, with the integration
fixture in `tests/gptk4/display_fix_probe.c`.

The public GPTK4 build uses the same qualified runtime archive; its 43 native
project components retain their Developer ID signatures, and the six imported
Apple native components retain their original signatures. Apple's complete
framework and matching redistributables remain unmodified. The existing
MacVolvo 1.0 DMG retains SHA-256
`9db10b59ea5d94fb5b259ed971e14032dbed52489a6da77c8b0bd38461003c7a`.

## Signed evaluation release

Public evaluation **1.0 build 8** uses bundle identifier `app.macvolvo.gptk4`
and Developer ID team `QZTVN6KK9H`. The ad-hoc builds described above record
earlier local testing; the public download is signed, notarized and stapled.

Apple accepted both submissions on October 17, 2026:

- App plus unpacked runtime: `75ba3c06-ad08-4b35-87ab-93e560b15c04`.
- DMG: `1e5f7d5d-89cc-4e97-bca4-7ced0418345b`.

Both staples validate, and Gatekeeper accepts the app and DMG as
`Notarized Developer ID`. The qualified app is
`runtime/build/gptk4/release-1/MacVolvo GPTK4.app`.
Installer: `runtime/release/MacVolvo-GPTK4-1.0.dmg` (254,236,592 bytes).
SHA-256: `d802687441c30b8e5344873100dbfc062c1b3857eee2bf9e07236a7814cf0df0`.

The [separate evaluation release](https://github.com/haeli05/MacVolvo/releases/tag/v1.0-gptk4-eval.1)
includes the DMG, checksum and a validation summary. The original v1.0 assets
are retained; this prerelease does not replace the normal app's update feed.

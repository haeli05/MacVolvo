# Deadlock settings and missing Steam window

Report investigated October 17, 2026, for the original MacVolvo/DXMT app.
The reporter uses an M2 MacBook Air. Changing graphics presets, resolution or
aspect ratio reportedly moves the displayed UI away from its click targets;
one occurrence rendered only in the top-left quarter. Later, Open Steam did
not show a window although Deadlock still launched. This is separate from the
GPTK4 evaluation's observed oversized fullscreen window.

## Steam window request

The launch worker used to activate steam.exe's macOS application when Open
Steam found an existing client. Steam can be running silently in the tray;
its browser window belongs to another Wine process. Activating steam.exe is
not a request to restore that browser window. When only a game remained,
the worker also returned without opening a window or reporting an error.

`openSteamWindow` now sends `steam://open/main` to the existing owned Steam
client through a temporary Steam IPC request. Both idle-client and running-game
paths use it. The worker waits for and reaps the request, with the same 15-second
deadline used for game-launch requests. It does not stop the game, restart Wine
or edit the live Steam configuration. If the owned Steam client has exited,
it reports that the game must finish before Steam can reopen. Failure of the
temporary request is also reported instead of returning success.

The Swift launcher recognizes this as an existing Steam session without a
90-second window wait. It also leaves Steam's activation in place: previously
its final window check preferred the visible game and could focus it again.

This addresses the confirmed missing window-request path. It does not prove
that the remote reporter's browser is healthy or that every missing-window
condition has the same cause. Existing idle-client browser recovery still
handles helpers replaced by Steam updates.

Four native regression checks cover the actual helper and running-session
branch with disposable stubs: the window request and deadline, Play focusing
the existing game, an absent client, and a failed request. The complete
portable suite passes 137 tests.
The Swift launch-readiness checks also pass, including a Steam restore event
with no window polling. A complete local DXMT app build and its build-proof
file hashes verify at `runtime/build/deadlock-settings/candidate-final/MacVolvo.app`.
That candidate is ad-hoc signed for local testing, not a notarized download.

## Display investigation

No display-driver, renderer, DPI or resolution-policy change is made for this
report. The GPTK4 resize watcher remains disabled for the original app.

`tests/deadlock/display_changes.c` exercises the shipped signed DXMT runtime in
a disposable Wine prefix. The window uses per-monitor DPI awareness and requests
DXGI fullscreen. All ten geometry checkpoints passed on the development M2 Max:
windowed startup, fullscreen, lower resolution, 4:3, 16:9, same-size buffer
recreation, the original size, a fullscreen toggle, and construction of a
replacement swap chain before and after releasing its predecessor. Window
client and buffer dimensions remained equal at each checkpoint. Presentation
logs also recorded matching source/drawable aspect ratios for size changes.

Local results and logs are under `runtime/build/deadlock-settings/`. These are
synthetic geometry checks, not Deadlock UI/input validation or an M2 Air test.
The reported misalignment has not been reproduced or fixed by this work.
Reproduction still needs the affected game's exact video options, the sequence
of setting changes and a capture of the window, presentation and input geometry
while the UI is displaced.

Temporary recovery to try: close Deadlock, disable its Fullscreen option in
MacVolvo, select a resolution that fits the display and reopen the game. Removing
`-fullscreen` only in Steam Properties is temporary: MacVolvo synchronizes its
saved per-game launch choices back to Steam. Use the app's Fullscreen control
for a persistent windowed choice. The reporter still needs to verify recovery.

The Steam window changes ship in [MacVolvo 1.1](releases/v1.1.md), using the
original signed DXMT/Wine runtime. The Deadlock display issue remains unresolved.
The v1.0 and GPTK4 evaluation installers are retained.

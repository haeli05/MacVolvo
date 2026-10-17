# MacVolvo

**Counter-Strike 2 and Deadlock on Apple Silicon.**

A free, open-source Mac launcher built on [Recall](https://github.com/AsherJN/recall).
Install Steam, choose your game, and play through Wine and DXMT.

## [⬇ MacVolvo · DXMT](https://github.com/haeli05/MacVolvo/releases/download/v1.0/MacVolvo-1.0.dmg) · [⬇ MacVolvo GPTK4](https://github.com/haeli05/MacVolvo/releases/download/v1.0-gptk4-eval.1/MacVolvo-GPTK4-1.0.dmg)

Both downloads are Developer ID signed, Apple notarized and stapled.

**MacVolvo GPTK4** is a separate evaluation app using Apple's D3DMetal 4.0 beta 3
for DirectX 11. It has its own Steam setup and does not automatically import
existing games. No FPS improvement over the original app has been established.
See the [GPTK4 release notes](docs/releases/v1.0-gptk4-eval.1.md).

[Introduction](https://haeli05.github.io/MacVolvo/) ·
[Downloads & releases](https://github.com/haeli05/MacVolvo/releases) ·
[Report a bug](https://github.com/haeli05/MacVolvo/issues)

> **v1.0 release candidate.** Known launch, audio and performance issues remain.
> Read the release notes before downloading. Build 6 is Developer ID signed and
> notarized; the installer is available in the [v1.0 prerelease](https://github.com/haeli05/MacVolvo/releases/tag/v1.0).

## What it does

Valve dropped macOS support when Counter-Strike 2 replaced CS:GO, and Deadlock has never
had a Mac version. MacVolvo installs the Windows version of Steam into a private Wine
environment, and you play from there, with no CrossOver, Windows or Boot Camp needed.

MacVolvo builds on [Recall](https://github.com/AsherJN/recall), Joshua Asher Nelson's
work on running Overwatch on the Mac. Its performance results are not CS2 or
Deadlock benchmarks.

- **Wine**, built from CodeWeavers' CrossOver 26.3 sources, runs Steam and the games.
- **Rosetta** translates the games' Intel code to Apple Silicon.
- **DXMT** translates the games' Direct3D 11 graphics to Metal, with Recall's faster waits,
  frame pacing, third frame buffer and image compression kept on.
- **Raw mouse input** reads the mouse directly, up to 2,000 times a second, instead of
  waiting on macOS's pointer.
- **Game Mode**: each game starts as a Mac game, so macOS gives it priority.

See [how Recall runs faster](docs/HOW-IT-WORKS.md) for the engine details.

## Get started

1. **Download MacVolvo** from [GitHub Releases](https://github.com/haeli05/MacVolvo/releases).
   Read the package’s signing status and installation instructions, then move MacVolvo to Applications.
2. **Open MacVolvo** and follow the setup steps. It prepares everything and installs Steam.
3. **Open Steam, sign in,** and install Counter-Strike 2 or Deadlock from your Library.
4. **Pick a game in MacVolvo and press Play.**

| You need | |
|---|---|
| Mac | Apple Silicon (M1 or newer). Intel Macs aren't supported. |
| macOS | macOS Tahoe 26.5 or later |
| Memory | 16 GB recommended |
| Storage | About 70 GB free per game |
| Also | A Steam account, an internet connection, and Rosetta (MacVolvo checks for it) |

## About VAC

Counter-Strike 2 and Deadlock are protected by VAC, Valve's anti-cheat. MacVolvo runs the
games unmodified through Wine, the way Linux players have used Proton for years, but Valve
doesn't support playing them on macOS this way and we can't promise VAC won't object. Play on
an account you're prepared to take that risk with.

## Known issues

- **Black screen with sound on launch:** quit the game completely and restart it.
  This can happen from either MacVolvo or Steam. A captured fullscreen deadlock is
  fixed, but the intermittent symptom is not considered fully resolved.
- **Audio static or crackling:** open **Audio MIDI Setup → Window → Show Audio Devices**,
  select your output device, and set **Format to 96,000 Hz (96 kHz)** if supported.
  Quit and restart the game afterward. This workaround helped on the tested M2 Max;
  MacVolvo does not change your system audio format.
- **CS2 combat lag spikes / severe FPS drops:** still under investigation.
  Shader compilation can cause initial stutters, but it does not explain every report.
- **Deadlock camera stops responding after a match:** clicks may still work.
  Quit and restart the game. Post-match recovery has not been fully verified.
- **Steam store/profile flicker:** pages may flicker while loading.

See [v1.0 release notes](docs/releases/v1.0.md) for the current validation limits.

## Building from source

See [build instructions](docs/BUILDING.md) and the [architecture notes](app/ARCHITECTURE.md).
MacVolvo uses Recall 1.3.0's runtime with a mouse timing fix; the MacVolvo-specific pieces are the Steam
worker (`scripts/portable_steam.h`), the Steam window fix (`scripts/webhelper_wrapper.c`) and
the app. [docs/HANDOFF.md](docs/HANDOFF.md) records how the Steam window fix was found.

## Credits and license

MacVolvo is a fork of [Recall](https://github.com/AsherJN/recall), created by Joshua Asher
Nelson. It uses Wine from CodeWeavers' published CrossOver sources, DXMT by Feifan He through
NerRobDog's fork, and Soju's runtime build recipe.

The original code is licensed under [Apache 2.0](LICENSE). Dependencies and patches keep
their own licenses; see the [third-party notices](THIRD_PARTY_NOTICES.md) and [NOTICE](NOTICE).

MacVolvo is an independent community project, not affiliated with or endorsed by Valve
Corporation, Volvo, Blizzard Entertainment, Apple or CodeWeavers. Counter-Strike, Deadlock,
Steam, Mac, CrossOver and other product names are trademarks of their respective owners.

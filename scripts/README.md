# Scripts

| Script | What it does |
|---|---|
| `QuickCheck.command` | Debug build, copied into `build/QCpie.app` (and `/Applications/QCpie.app` if present), then opened. Use this to test settings-dependent UI: the bare `.build/debug/QCpie` has its own UserDefaults domain. |
| `BuildApp.sh` | Release app bundle in `build/` (runs the design lint). Packaging only. |
| `Release.sh` | `build`: tests, `BuildApp.sh`, `build/QCpie.dmg`. `publish "notes"`: after the DMG launched on the macOS 15 Mac, pushes, tags and publishes the GitHub release. Only when asked to release. |
| `Build.command` | Double-click wrapper: `BuildApp.sh`, then opens `build/`. |
| `Start_QCpie.command` | Double-click wrapper: opens `build/QCpie.app`, building it first if missing. |
| `design_lint.py` | UI must use the design tokens (DESIGN.md). `--update` after removing old debt. |
| `LineFinderBench/run.sh` | Line Check accuracy and cost. Must print ALL PASSED. |
| `FrameCheckBench/run.sh` | Frame Check and legal range accuracy. Must print ALL PASSED. |
| `LoudnessBench/run.sh` | Loudness against ffmpeg `ebur128`. Must print ALL PASSED. |
| `LaunchBench/run.sh` | Launch time against an empty SwiftUI app. Must print ALL PASSED. |

Benchmarks that use real footage read `_TEST/` (local, git-ignored) and skip those cases without it.

# おはぎー (Ohagey)

**Ohagey** is an unofficial, from-scratch Windows IME (Text Services Framework) that
reuses [azooKey](https://github.com/azooKey/azooKey)'s neural kana-kanji conversion
engine ([AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) + **Zenzai**),
paired with a native Win32 TSF front-end derived from Microsoft's official
[SampleIME](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/IME).

> 🍡 The name is a pun on 「アズキー(azooKey)」→「おはぎ(ohagi, a red-bean-paste sweet)」+「ー」,
> continuing the red-bean theme of the original project name while avoiding any trademarked
> product names (e.g. Imuraya's registered "あずきバー").

This is **not** affiliated with azooKey, Microsoft, or the existing
[azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows) (fkunn1326) or
[myime](https://github.com/unok/myime) (unok) projects. It is a new, independent
implementation that borrows architectural ideas from both.

## Why another Windows IME?

azooKey already runs great on iOS and macOS. Windows is the missing platform. The existing
community port (azooKey-Windows) is currently unmaintained, so Ohagey is a fresh
implementation that:

- Reuses **Zenzai** (via AzooKeyKanaKanjiConverter) for high-accuracy neural conversion
- Rebuilds the TSF layer, UI, and packaging from scratch
- Prioritizes low input latency and a modern (Fluent Design) candidate window

## Architecture at a glance

```
┌──────────────────────────────┐        Named Pipe        ┌──────────────────────────────┐
│  tsf/  (C++, per-app process) │◄──────(Protobuf, ACL,───►│  engine/ (Swift, single       │
│  - TSF COM implementation      │        session-scoped)   │  shared server process)       │
│    (vendored from SampleIME)   │                           │  - AzooKeyKanaKanjiConverter  │
│  - Candidate window             │                           │    + Zenzai (CPU/CUDA/Vulkan) │
│    (DirectWrite/DirectComposition,                          │  - On-demand start, idle      │
│    Fluent Design)                                            │    timeout shutdown           │
│  - SEH-wrapped, crash-isolated  │                           └──────────────────────────────┘
└──────────────────────────────┘
                │ reads/writes
                ▼
     %LOCALAPPDATA%\Ohagey\   (per-user settings, learning data, user dictionary)

┌──────────────────────────────┐
│  settings-app/ (WinUI 3)      │  Backend selection, user dictionary, learning data
│  - writes to registry/settings│  reset, model status
│    file; TSF/engine watch for │
│    changes and hot-reload     │
└──────────────────────────────┘
```

See [`docs/decisions/`](docs/decisions) for the full history and rationale behind each
architectural decision (TSF choice, IPC design, model distribution, licensing, etc.).

## Repository layout

| Path | Contents |
|---|---|
| `tsf/` | C++ TSF text service (vendored from Microsoft SampleIME, heavily modified) |
| `engine/` | Swift Package: shared conversion server process wrapping AzooKeyKanaKanjiConverter + Zenzai |
| `settings-app/` | WinUI 3 settings application |
| `installer/` | Inno Setup script and build assets |
| `docs/decisions/` | Architecture decision log (one file per major decision) |
| `.github/workflows/` | CI: MSBuild (TSF) + Swift build (engine) + Inno Setup packaging |

## Status

🚧 Early scaffolding stage. Architecture finalized; implementation in progress.

## License

Ohagey's own source code is licensed under the [MIT License](LICENSE).

This project depends on and redistributes/links against:
- Microsoft SampleIME (Windows-classic-samples) — MIT
- AzooKeyKanaKanjiConverter / azooKey — MIT
- Zenzai model weights (`zenz-v3.1-small` by Miwa Keita) — **CC-BY-SA 4.0**, downloaded
  separately at first run, not bundled in this repository or the installer. See
  [`docs/decisions/0009-model-license.md`](docs/decisions/0009-model-license.md) for details
  and required attribution.

## Privacy

Ohagey works fully offline after the initial model download. No keystrokes, conversion
history, or telemetry are ever sent externally. See
[`docs/decisions/0016-privacy.md`](docs/decisions/0016-privacy.md).

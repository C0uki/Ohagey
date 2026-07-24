# Architecture Decision Log

This is a running log of the major architectural decisions made for Ohagey, in the
order they were decided. Each row links to a short rationale document where one exists;
otherwise the summary here is the full record.

| # | Decision | Outcome |
|---|---|---|
| 0001 | Base approach | Reuse only the Zenzai conversion engine (AzooKeyKanaKanjiConverter); rebuild TSF, UI, packaging from scratch |
| 0002 | TSF base | Microsoft SampleIME (Windows-classic-samples), vendored and heavily modified |
| 0003 | TSF implementation language | C++ (not Swift — Swift's COM support is proven for *consuming* COM/WinRT, not for *implementing* many server-side TSF interfaces) |
| 0004 | Engine process model | Single shared server process (Mozc-style), not in-proc DLL — required once Zenzai's memory/GPU footprint was accounted for |
| 0005 | Engine implementation language | Swift, entire server process (no C++/Swift FFI boundary — eliminated once the engine moved to its own process) |
| 0006 | IPC transport | Named pipe, session-ID-scoped name, explicit ACL for AppContainer/elevated processes |
| 0007 | IPC message format | Protocol Buffers (matches Mozc's proven approach) |
| 0008 | [Model distribution](0008-model-distribution.md) | Downloaded from Hugging Face by the Inno Setup installer at install time; install still succeeds if the download fails, with a dictionary-only fallback |
| 0009 | [Model license](0009-model-license.md) | zenz-v3.1-small is CC-BY-SA 4.0, kept as a separately-downloaded asset, distinct from Ohagey's MIT code, with mandatory attribution |
| 0010 | Inference backend | CPU / CUDA / Vulkan, user-selectable in settings |
| 0011 | Candidate window rendering | Native Win32 + DirectWrite/DirectComposition (not WebView2) — latency priority |
| 0012 | Candidate window visual style | Windows 11 Fluent Design (Mica, accent color, light/dark follow OS) |
| 0013 | Settings app | WinUI 3 |
| 0014 | Settings propagation | Registry/settings file + change notification (`RegNotifyChangeKeyValue` / `ReadDirectoryChangesW`), not active IPC broadcast |
| 0015 | Server lifecycle | On-demand start (first client triggers launch-if-not-running), idle-timeout shutdown |
| 0016 | [Privacy](0016-privacy.md) | Fully offline after model download; no telemetry, no external transmission of input |
| 0017 | TSF crash resilience | SEH (`__try`/`__except`) around all TSF DLL code paths |
| 0018 | Supported platforms | x64 only (Windows 10/11); ARM64 deferred |
| 0019 | Installer | Inno Setup |
| 0020 | Build orchestration | MSBuild with a custom target invoking `swift build` for the engine |
| 0021 | Dependency vendoring | SampleIME vendored (copy, heavily modified); AzooKeyKanaKanjiConverter via Swift Package Manager |
| 0022 | Project license | MIT (matches all MIT-licensed dependencies) |
| 0023 | Project name | **Ohagey (おはぎー)** — pun on azooKey → ohagi (a red-bean sweet), avoiding trademarked names like Imuraya's "あずきバー" |
| 0024 | Learning/memory data location | `%LOCALAPPDATA%\Ohagey\`, passed to AzooKeyKanaKanjiConverter as `memoryDirectoryURL` |
| 0025 | Learning enabled by default | Yes, with one-click disable/reset in settings (handles shared/school PCs) |
| 0026 | Explicit user dictionary | In initial scope (separate file under `%LOCALAPPDATA%\Ohagey\`) |
| 0027 | Dictionary import from other IMEs | Deferred to a future release |

## Open items for implementation phase
- Exact user dictionary file format (JSON vs. other) — left for implementation
- Exact registry schema for settings (Decision 0014)
- Protobuf schema definitions for the IPC protocol (Decision 0007)

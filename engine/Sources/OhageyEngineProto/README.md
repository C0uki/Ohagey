# OhageyEngineProto

This target will hold the Swift types generated from `.proto` schema definitions
(decision 0007) describing the IPC protocol between `tsf/` (C++ client) and
`engine/` (Swift server), e.g.:

- `ConvertRequest` / `ConvertResponse` (reading → candidate list)
- `CommitRequest` (confirm a candidate, feed learning data)
- `RegisterWordRequest` (explicit user dictionary entry, decision 0026)
- `SettingsChanged` notification (if needed beyond decision 0014's file-watch approach)

The `.proto` source files and the `protoc` + `swift-protobuf` generation step will be
added once IPC implementation begins.

// OhageyEngine
//
// Single shared conversion server process (decision 0004/0005).
// Launched on-demand by a TSF client (decision 0015); listens on a
// session-ID-scoped named pipe (decision 0006) speaking Protobuf (decision 0007);
// wraps AzooKeyKanaKanjiConverter + Zenzai for the actual conversion (decision 0001).
//
// TODO (implementation phase):
// 1. Determine current Windows session ID -> derive pipe name
//    (\\.\pipe\ohagey_session_<SessionId>)
// 2. Create the named pipe with an explicit security descriptor that allows
//    connections from AppContainer / low-integrity / elevated processes
//    (decision 0006 — see docs/decisions/README.md row 0006)
// 3. Load ConvertRequestOptions:
//    - memoryDirectoryURL / sharedContainerURL -> %LOCALAPPDATA%\Ohagey\
//      (decision 0024)
//    - learningType -> read from settings (decision 0025 default: enabled)
//    - zenzaiMode -> .on(weight: <model path>, ...) if model present,
//      else .off fallback (decision 0008)
// 4. Watch settings (registry/file) for backend changes (CPU/CUDA/Vulkan,
//    decision 0010) and hot-reload without dropping active connections
//    (decision 0014)
// 5. Idle-timeout self-termination when zero clients are connected
//    (decision 0015)

print("OhageyEngine: scaffold only, not yet implemented.")

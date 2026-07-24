; Ohagey installer (Inno Setup) — decision 0019
;
; This is a scaffold, not a working script yet. Fill in [Files] once tsf/, engine/,
; and settings-app/ produce real build outputs.

#define MyAppName "Ohagey"
#define MyAppVersion "0.0.1"
#define MyAppPublisher "Ohagey Contributors"
#define MyAppURL "https://github.com/REPLACE_ME/ohagey"

[Setup]
AppId={{REPLACE-WITH-GENERATED-GUID}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\Ohagey
DefaultGroupName=Ohagey
; x64-only (decision 0018)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=ohagey-setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
; TSF registration (regsvr32-equivalent) requires admin.

[Files]
; TODO: TSF DLL, OhageyEngine.exe, settings app, once build outputs exist.
; Source: "..\tsf\build\x64\Release\Ohagey.dll"; DestDir: "{app}"; Flags: regserver 64bit
; Source: "..\engine\.build\release\OhageyEngine.exe"; DestDir: "{app}"

[Run]
; Model download (decision 0008) — continues installation on failure (decision 0008).
; TODO: replace with a proper download step (e.g. via Inno Download Plugin) that
; does not fail the install on network errors, per docs/decisions/0008-model-distribution.md
; Filename: "{app}\download-model.ps1"; Parameters: "-Url https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf -Dest ""{app}\models\ggml-model-Q5_K_M.gguf"""; Flags: runhidden; StatusMsg: "Downloading conversion model..."

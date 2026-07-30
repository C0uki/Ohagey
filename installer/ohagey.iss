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
; Layout is decision 0033. The TSF DLL and the engine must land in the SAME
; directory: the DLL starts the engine on demand (decision 0015) by looking for
; OhageyEngine.exe beside itself, rather than reading a path from the registry.
;
; Still commented out: the settings app does not exist yet, and none of this has
; been run through iscc. The paths below are the real build outputs.
;
; Source: "..\tsf\SampleIME\x64\Release\SampleIME.dll"; DestDir: "{app}"; DestName: "OhageyTSF.dll"; Flags: regserver 64bit
; Source: "..\engine\.build\release\OhageyEngine.exe"; DestDir: "{app}"
; Source: "..\settings-app\bin\x64\Release\OhageySettings.exe"; DestDir: "{app}"
;
; Backend DLLs (decision 0028). The engine picks one at startup via the DLL
; search path, so each backend needs its own subdirectory.
; Source: "..\backends\cpu\*.dll"; DestDir: "{app}\backends\cpu"
; Source: "..\backends\cuda\*.dll"; DestDir: "{app}\backends\cuda"
; Source: "..\backends\vulkan\*.dll"; DestDir: "{app}\backends\vulkan"

[Dirs]
; The model is downloaded after install (decision 0008), so the directory has to
; exist first.
Name: "{app}\models"

[Run]
; Model download (decision 0008) — continues installation on failure (decision 0008).
; TODO: replace with a proper download step (e.g. via Inno Download Plugin) that
; does not fail the install on network errors, per docs/decisions/0008-model-distribution.md
; Filename: "{app}\download-model.ps1"; Parameters: "-Url https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf -Dest ""{app}\models\ggml-model-Q5_K_M.gguf"""; Flags: runhidden; StatusMsg: "Downloading conversion model..."

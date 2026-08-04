; Ohagey installer (Inno Setup) — decision 0019
;
; This is a scaffold, not a working script yet. Fill in [Files] once tsf/, engine/,
; and settings-app/ produce real build outputs.
;
; `download-model.ps1` beside this file IS real and has been exercised standalone
; (already-present, hash match, hash mismatch, offline, and no leftovers after a
; failed fetch). Only its wiring below waits on the rest of the scaffold.

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
; The project directory is still the vendored SampleIME one; the artefact is
; already the shipping name, so no DestName rename is needed (decision 0033).
; Source: "..\tsf\SampleIME\x64\Release\OhageyTSF.dll"; DestDir: "{app}"; Flags: regserver 64bit
; Source: "..\engine\.build\release\OhageyEngine.exe"; DestDir: "{app}"
; Source: "..\settings-app\bin\x64\Release\OhageySettings.exe"; DestDir: "{app}"
;
; Backend DLLs (decision 0028). The engine picks one at startup via the DLL
; search path, so each backend needs its own subdirectory.
; Source: "..\backends\cpu\*.dll"; DestDir: "{app}\backends\cpu"
; Source: "..\backends\cuda\*.dll"; DestDir: "{app}\backends\cuda"
; Source: "..\backends\vulkan\*.dll"; DestDir: "{app}\backends\vulkan"
;
; Installed rather than run from a temporary copy, so that a repair install and
; a later retry from the settings app both have it to hand.
; Source: "download-model.ps1"; DestDir: "{app}"

[Dirs]
; The models are downloaded after install (decision 0008), so the directory has
; to exist first.
Name: "{app}\models"

[Run]
; Models are downloaded rather than bundled (decision 0008), and a failure here
; must not fail the installation: download-model.ps1 always exits 0 and records
; what happened in {app}\models\download.log.
;
; Every file is pinned by SHA-256. Not for the transport — this is HTTPS — but
; for the source: these come from third-party Hugging Face repositories that can
; change at any time. The hashes below are the files this build was tested
; against, verified against upstream on 2026-08-04. A change upstream then shows
; up as a skipped download rather than as a user running weights nobody here has
; ever seen.
;
; `powershell.exe` rather than naming the .ps1 directly: Inno hands Filename to
; whatever is registered for the extension, which on a default Windows is
; Notepad.

; ── Zenzai weights (decisions 0008 / 0009 — CC-BY-SA 4.0) ──────────────────
; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf -Dest ""{app}\models\ggml-model-Q5_K_M.gguf"" -Sha256 4DE930C06BEF8C263AA1AA40684AF206DB4CE1B96375B3B8ED0EA508E0B14F6C"; Flags: runhidden; StatusMsg: "Downloading conversion model..."

; ── Base language model (decision 0034) ────────────────────────────────────
;
; Four files, 42.6 MB. WITHOUT THESE, PERSONALISATION IS INERT — not weak,
; inert. The engine falls back to an empty base model, and Zenzai's
; alpha * (log p_personal - log p_base) against a base that scores every token
; identically moves nothing. Measured: 40 confirmations changed no ranking and
; broke none of 30 eval items, against 2nd->1st and 18 broken with the real
; base. Switching personalisation on in the settings app does nothing without
; these files.
;
; LICENCE: Miwa-Keita/base_n5_lm states NO licence — no licence field, no tag,
; no LICENSE file (checked 2026-08-04). Unlike the Zenzai weights (CC-BY-SA 4.0)
; there is nothing to comply with and nothing to attribute under. Nothing is
; redistributed here — the files are fetched on the user's own machine from the
; author's own repository — but that is a narrower position than decision 0009
; takes for the weights, and it is written down in decision 0009's addendum
; rather than assumed.
; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/lm_c_abc.marisa -Dest ""{app}\models\lm_c_abc.marisa"" -Sha256 AB9CFB9B4231B1187934109776339001A9CB089A9D0FA8ED160C79508C8783A3"; Flags: runhidden; StatusMsg: "Downloading personalisation model (1 of 4)..."
; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/lm_r_xbx.marisa -Dest ""{app}\models\lm_r_xbx.marisa"" -Sha256 F9594D23E2F15A8E6D51811F15B23E23BFC7CEFD24B8B1C06F3F0366CE5BF555"; Flags: runhidden; StatusMsg: "Downloading personalisation model (2 of 4)..."
; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/lm_u_abx.marisa -Dest ""{app}\models\lm_u_abx.marisa"" -Sha256 6656BB6BEA01F75A2156009B7B104ADBD6BF897CFF47635FD907215F2BC727E9"; Flags: runhidden; StatusMsg: "Downloading personalisation model (3 of 4)..."
; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/lm_u_xbc.marisa -Dest ""{app}\models\lm_u_xbc.marisa"" -Sha256 69F43384DC45FD16F45E19CBDF242E67F5F8433168DADFE2012ABB7657D38041"; Flags: runhidden; StatusMsg: "Downloading personalisation model (4 of 4)..."

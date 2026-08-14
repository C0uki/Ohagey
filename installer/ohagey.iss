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
#define MyAppURL "https://github.com/C0uki/Ohagey"

[Setup]
; Generated once, 2026-08-04. This is what Windows uses to recognise an
; existing installation, so it must never change: a new one turns every
; upgrade into a second, parallel copy of Ohagey.
; The doubled brace is Inno's escape for a literal `{`.
AppId={{FA549B8C-7981-4ABE-A7CC-1F7DC99E15E7}
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
; The paths were checked against what the builds actually produce, and two of
; the three were wrong when nobody had run iscc over them (decision 0033).
; All three are built and packaged now.
;
; -- ignoreversion on everything we build ------------------------------------
;
; Inno compares version resources and skips a file it thinks is not newer.
; None of our binaries bump one: the TSF DLL carries the vendored sample's
; version resource, the Swift engine has none, and the settings app's does not
; move between builds. Without `ignoreversion` the first install wins forever
; and every later one silently keeps the old files.
;
; Measured: a reinstall carrying a rebuilt OhageyTSF.dll left the previous DLL
; in place, with nothing in the log to say so. The registration that followed
; then registered the *old* build.
;; The project directory is still the vendored SampleIME one; the artefact is
; already the shipping name, so no DestName rename is needed (decision 0033).
; -- restartreplace: an in-use TSF DLL cannot be overwritten ----------------
;
; Once the DLL is registered as a text service, Windows loads it into every
; process with a text input surface. Measured on an ordinary desktop, an
; upgrade found it held by SearchHost, Discord, LINE and the terminal doing
; the upgrading -- five processes, none of them ours.
;
; Without this flag the install fails on `DeleteFile: The existing file
; appears to be in use (5)`, and in silent mode it simply cancels. Inno's
; other answer is RestartManager, which offers to *close* those applications;
; closing someone's chat client to update an IME is not a trade to make
; silently.
;
; `restartreplace` queues the replacement with MoveFileEx instead, so it
; happens on the next sign-in. `uninsrestartdelete` does the same on the way
; out. This is why IME installers ask you to sign out.
Source: "..\tsf\SampleIME\x64\Release\OhageyTSF.dll"; DestDir: "{app}"; Flags: regserver 64bit ignoreversion restartreplace uninsrestartdelete
;
; -- The engine: the architecture triple, not .build\release ----------------
;
; SwiftPM makes `.build\release` a *symbolic link* to the triple directory,
; and creating one on Windows needs Developer Mode or elevation. It fails on an
; ordinary machine -- every build here prints "unable to create symbolic link"
; with I/O error 512 and leaves no such directory. Naming the link would make
; packaging fail on exactly the machines that cannot create it.
Source: "..\engine\.build\x86_64-unknown-windows-msvc\release\OhageyEngine.exe"; DestDir: "{app}"; Flags: ignoreversion
;
; -- The settings app: a directory, not a file -------------------------------
;
; `WindowsAppSDKSelfContained` and `RuntimeIdentifier=win-x64` mean the build
; output is the app *and* its copy of the Windows App Runtime -- a few dozen
; files. Shipping only OhageySettings.exe would install something that cannot
; start, and self-contained was chosen precisely to stop it asking to download
; a runtime after installation (decision 0016).
;
; The TFM and RID are part of the path and change with them.
Source: "..\settings-app\src\Ohagey.Settings\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
;
; Backend DLLs (decision 0028). The engine picks one at startup via the DLL
; search path, so each backend needs its own subdirectory.
;
; CPU is always in: it is 2.4 MB and it is the one that works on every
; machine, with no driver and no vendor runtime.
Source: "..\backends\cpu\*.dll"; DestDir: "{app}\backends\cpu"; Flags: ignoreversion
;
; GPU backends are opt-in at packaging time, because CUDA alone is 977 MB --
; four hundred times the CPU one, and most of it is the vendor runtime. An
; installer that carries it by default would be a gigabyte for a feature many
; machines cannot use.
;
;     iscc /DGpuBackends installer\ohagey.iss
;
; `skipifsourcedoesntexist` because `tools/fetch-backends.ps1` fetches only
; what it is asked for: requesting the define should not require having
; fetched every backend.
#ifdef GpuBackends
Source: "..\backends\cuda\*.dll"; DestDir: "{app}\backends\cuda"; Flags: skipifsourcedoesntexist
Source: "..\backends\vulkan\*.dll"; DestDir: "{app}\backends\vulkan"; Flags: skipifsourcedoesntexist
#endif
;
; Installed rather than run from a temporary copy, so that a repair install and
; a later retry from the settings app both have it to hand.
Source: "download-model.ps1"; DestDir: "{app}"; Flags: ignoreversion
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
; for what is on the other end. The Zenzai weights come from a third-party
; Hugging Face repository that can change at any time; the base language model
; is ours, and pinning it means a release asset replaced by accident shows up
; as a skipped download rather than as a user running a model nobody here has
; tested. The hashes are what this build was tested against.
;
; `powershell.exe` rather than naming the .ps1 directly: Inno hands Filename to
; whatever is registered for the extension, which on a default Windows is
; Notepad.

; ── Zenzai weights (decisions 0008 / 0009 — CC-BY-SA 4.0) ──────────────────
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf -Dest ""{app}\models\ggml-model-Q5_K_M.gguf"" -Sha256 4DE930C06BEF8C263AA1AA40684AF206DB4CE1B96375B3B8ED0EA508E0B14F6C"; Flags: runhidden; StatusMsg: "Downloading conversion model..."

; -- Base language model (decisions 0009 / 0034) ---------------------------
;
; Five files, 9.4 MB, built by us. `tools/build-base-lm.ps1` produces them
; from an archived Wikipedia corpus; both are published as release assets.
;
; WITHOUT THESE, PERSONALISATION DOES NOTHING. The engine refuses to apply a
; personal model unless it can be trained by resuming from this one, because
; the alternative -- training from nothing -- is what breaks 8 to 18 of 30
; unrelated conversions (decision 0034). Missing files therefore cost the
; feature, not the user's conversion quality.
;
; -- Why not Miwa-Keita/base_n5_lm any more --------------------------------
;
; It was here until 2026-08-04 and has been removed. Two independent reasons,
; either of which is enough:
;
;   * it publishes four files and SwiftTrainer(baseFilePattern:) needs five.
;     With four, the only personal model that can be built is the harmful
;     one -- so shipping it meant shipping a setting that makes conversion
;     worse;
;   * it states no licence at all (no field, no tag, no LICENSE file), which
;     decision 0009 could only meet with a narrow "we do not redistribute"
;     position.
;
; Ours is 9.4 MB rather than 42.6 MB, and that is deliberate. The personal
; model is trained by resuming from this one, so it ends up the same size,
; and each retraining costs about a second and 48 MB of peak memory per
; megabyte of base -- on the user's machine, every time they correct a few
; words. 42.6 MB would mean 41 seconds and 2 GB. 9.4 MB scores the same
; 30-of-30 on the evaluation set (decision 0034).
;
; LICENCE: CC BY-SA 4.0, inherited from Japanese Wikipedia. The same licence
; as the Zenzai weights, so decision 0009's arrangement covers it unchanged:
; a separate artefact, attributed in the settings app, with Ohagey's own code
; staying MIT. The corpus is published alongside because share-alike is about
; the source, not only the derivative.
;
; Published as `base-lm-v1` on 2026-08-04. The hashes below were verified
; against the uploaded assets by running download-model.ps1 against them.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://github.com/C0uki/Ohagey/releases/download/base-lm-v1/lm_c_abc.marisa -Dest ""{app}\models\lm_c_abc.marisa"" -Sha256 4F164B78FF9D33694BD0ADB8A82D8D6EA833EE111F71D16CDE2E765EDBA07F30"; Flags: runhidden; StatusMsg: "Downloading personalisation model (1 of 5)..."
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://github.com/C0uki/Ohagey/releases/download/base-lm-v1/lm_c_bc.marisa -Dest ""{app}\models\lm_c_bc.marisa"" -Sha256 9CA26F3EB02691AE7FDB3154ADE612E107B87DBBE4CA0F67ACF6EFD4744E3CC2"; Flags: runhidden; StatusMsg: "Downloading personalisation model (2 of 5)..."
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://github.com/C0uki/Ohagey/releases/download/base-lm-v1/lm_r_xbx.marisa -Dest ""{app}\models\lm_r_xbx.marisa"" -Sha256 31BC54FCB7041847028E58F6BAC52703BAC785FAC10C5B6B17079C312A76D059"; Flags: runhidden; StatusMsg: "Downloading personalisation model (3 of 5)..."
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://github.com/C0uki/Ohagey/releases/download/base-lm-v1/lm_u_abx.marisa -Dest ""{app}\models\lm_u_abx.marisa"" -Sha256 9037787429C11D75903C9BB9F0C574E6DD146966D2800FE368DCDCAF1138ABC2"; Flags: runhidden; StatusMsg: "Downloading personalisation model (4 of 5)..."
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\download-model.ps1"" -Url https://github.com/C0uki/Ohagey/releases/download/base-lm-v1/lm_u_xbc.marisa -Dest ""{app}\models\lm_u_xbc.marisa"" -Sha256 D10C5413F543F7D8EC761ED81C99D4DE49C9608CCE003B2195DA6A218BB02FFD"; Flags: runhidden; StatusMsg: "Downloading personalisation model (5 of 5)..."

[Code]
// Stop the engine before replacing it.
//
// The engine is a background process of ours, started on demand by the TSF DLL
// (decision 0015). It is not the user's application, and it holds nothing that
// is not already on disk: learning is persisted as it goes, and personalisation
// trains into a staging directory and publishes atomically. The next conversion
// starts a fresh one.
//
// Without this, updating Ohagey while any application has the IME loaded fails
// and **rolls the whole installation back**:
//
//   DeleteFile: The existing file appears to be in use (5). Retrying.
//   ... An error occurred while trying to replace the existing file
//   User canceled the installation process. Rolling back changes.
//
// That is not a rare case. The TSF client holds its pipe connection open for as
// long as the IME is loaded, so the idle timeout never fires and the engine is
// running essentially whenever anyone has typed since logging in.
//
// Deliberately not Inno's CloseApplications: RestartManager sees the TSF DLL
// loaded into Discord, LINE, the shell, and offers to close *those*. Updating
// an IME must not close the user's chat client (decision 0033). This closes
// exactly one process, and it is ours.
//
// The DLL itself still cannot be replaced while it is loaded; that is what
// `restartreplace` on it is for, and why an update can still ask for a sign-out.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  // /F because it has no window to close politely; /IM so instances in other
  // sessions on a shared machine are included. A failure is not fatal: if there
  // was nothing to kill, taskkill returns non-zero and the install proceeds as
  // it always did.
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM OhageyEngine.exe',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

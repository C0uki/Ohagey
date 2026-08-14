# Fetches one model file at install time (decisions 0008 / 0009 / 0034).
#
# Called once per file from [Run] in ohagey.iss. Two things it must never do:
#
#   1. **Fail the installation.** A managed or offline machine (school, work)
#      is a normal case, not an error. Ohagey converts from the dictionary
#      until the model arrives, and the settings app can retry later
#      (decision 0008). So this always exits 0, and says why in the log.
#
#   2. **Leave a half-written file behind.** The engine decides whether Zenzai
#      is available by asking whether the file exists, and hands whatever it
#      finds to llama.cpp's gguf parser. A truncated download would be found,
#      loaded, and rejected -- or worse. Everything lands in `.partial` and is
#      renamed only after the whole file is there and its hash matches.
#
# Written for Windows PowerShell 5.1, which is what a fresh Windows has:
# Inno Setup runs `powershell.exe`, not `pwsh`.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Dest,

    # Expected SHA-256, pinned in ohagey.iss.
    #
    # Not paranoia about the transport -- this is HTTPS -- but about what is on
    # the other end. The Zenzai weights come from a third-party Hugging Face
    # repository that can be updated at any time; the base language model is
    # our own release asset, which can be replaced by accident. Either way,
    # pinning means an installer tested against a particular file keeps
    # installing that file, and a change shows up as a skipped download rather
    # than as a user with a model nobody here has ever run.
    [string]$Sha256 = "",

    [int]$TimeoutSec = 600,

    # Defaults beside the destination so it survives the installer exiting.
    [string]$LogPath = ""
)

# Not $ErrorActionPreference = "Stop": the whole point is to keep going.
$ErrorActionPreference = "Continue"

if (-not $LogPath) {
    $LogPath = Join-Path (Split-Path $Dest -Parent) "download.log"
}

function Write-Log([string]$message) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $message
    Write-Host $line
    # Best effort. Being unable to write the log is not a reason to skip the
    # download, and Inno runs this hidden so the console output goes nowhere.
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Get-Sha256([string]$path) {
    (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToUpperInvariant()
}

$name = Split-Path $Dest -Leaf

# -- Already there? ---------------------------------------------------------
if (Test-Path $Dest) {
    if (-not $Sha256) {
        Write-Log "$name : already present, no hash to check against -- keeping it"
        exit 0
    }
    if ((Get-Sha256 $Dest) -eq $Sha256.ToUpperInvariant()) {
        Write-Log "$name : already present and matches -- nothing to do"
        exit 0
    }
    # A repair install, or a partially-overwritten file. Replacing it is right:
    # the pinned hash is what this build was tested against.
    Write-Log "$name : present but does not match the expected hash -- refetching"
}

$partial = "$Dest.partial"
try { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue } catch { }

# TLS 1.2 has to be asked for on Windows PowerShell 5.1; without it the request
# to Hugging Face fails with a protocol error that looks like a network outage.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Invoke-WebRequest's progress bar makes a large download several times slower
# in 5.1, and nobody is watching it: this runs hidden.
$ProgressPreference = "SilentlyContinue"

Write-Log "$name : downloading from $Url"
try {
    Invoke-WebRequest -Uri $Url -OutFile $partial -TimeoutSec $TimeoutSec -UseBasicParsing
} catch {
    Write-Log "$name : download failed -- $($_.Exception.Message)"
    Write-Log "$name : continuing without it (decision 0008)"
    try { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue } catch { }
    exit 0
}

if (-not (Test-Path $partial)) {
    Write-Log "$name : download reported success but produced no file -- continuing without it"
    exit 0
}

if ($Sha256) {
    $actual = Get-Sha256 $partial
    if ($actual -ne $Sha256.ToUpperInvariant()) {
        # Deleted rather than kept: a file whose contents are not the ones this
        # installer was built against should not be loadable by the engine.
        Write-Log "$name : hash mismatch (expected $($Sha256.ToUpperInvariant()), got $actual) -- discarding"
        try { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue } catch { }
        exit 0
    }
}

try {
    Move-Item -LiteralPath $partial -Destination $Dest -Force
} catch {
    Write-Log "$name : could not move into place -- $($_.Exception.Message)"
    try { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue } catch { }
    exit 0
}

Write-Log ("$name : installed ({0:N1} MB)" -f ((Get-Item $Dest).Length / 1MB))
exit 0

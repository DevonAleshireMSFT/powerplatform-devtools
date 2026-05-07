#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive Power Platform solution download (export) script.

.DESCRIPTION
    Guides the user through selecting a PAC CLI auth profile, targeting a source
    environment, listing its solutions, exporting a chosen solution to a .zip file,
    and optionally unpacking it into a source-control-friendly folder structure.
    Supports sovereign clouds (GCC, GCC High, DoD).

.USAGE
    .\download.ps1
    .\download.ps1 -SolutionName "MySolution" -OutputZip ".\MySolution.zip"
    .\download.ps1 -SolutionName "MySolution" -OutputZip ".\MySolution.zip" -Managed -Unpack

.PARAMETER SolutionName
    Unique name of the solution to export. Listed and prompted interactively if omitted.

.PARAMETER OutputZip
    Path for the exported .zip file. Defaults to .\<SolutionName>.zip if omitted.

.PARAMETER Managed
    Export as a managed solution. Defaults to unmanaged.

.PARAMETER Unpack
    After export, unpack the solution into a folder using 'pac solution unpack'.
    The folder will be created alongside the zip (e.g. MySolution\).

.NOTES
    Requires: PAC CLI installed and available on PATH.
    Install : https://aka.ms/PowerAppsCLI
    For sovereign clouds, create an auth profile with the correct --cloud value:
      Commercial : (default, omit --cloud)
      GCC        : --cloud UsGov
      GCC High   : --cloud UsGovHigh
      DoD        : --cloud UsGovDod
#>

[CmdletBinding()]
param(
    [string] $SolutionName,
    [string] $OutputZip,
    [switch] $Managed,
    [switch] $Unpack,
    # Pass -NoStats (or set $env:PPDEVTOOLS_NO_STATS = '1') to suppress the usage stats summary.
    [switch] $NoStats
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Header([string]$Text) {
    Write-Host "`n$('─' * 60)" -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$('─' * 60)" -ForegroundColor DarkGray
}

function Write-Success([string]$Text) { Write-Host "  ✔  $Text" -ForegroundColor Green }
function Write-Info   ([string]$Text) { Write-Host "  ℹ  $Text" -ForegroundColor Gray }
function Write-Warn   ([string]$Text) { Write-Host "  ⚠  $Text" -ForegroundColor Yellow }
function Write-Fail   ([string]$Text) { Write-Host "  ✖  $Text" -ForegroundColor Red }

function Assert-PacCli {
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        Write-Fail "PAC CLI not found on PATH."
        Write-Info  "Install from: https://aka.ms/PowerAppsCLI"
        exit 1
    }
    $ver = (pac --version 2>&1) | Select-Object -First 1
    Write-Success "PAC CLI found: $ver"
}

function Get-PacAuthProfiles {
    $raw = pac auth list 2>&1
    $profiles = @()
    foreach ($line in $raw) {
        if ($line -match '^\s*\[(\d+)\]\s+(.+)') {
            $profiles += [PSCustomObject]@{
                Index = [int]$Matches[1]
                Raw   = $line.Trim()
            }
        }
    }
    return $profiles
}

function Select-AuthProfile {
    Write-Header "Authentication"

    $profiles = Get-PacAuthProfiles

    if ($profiles.Count -gt 0) {
        Write-Host "`n  Existing auth profiles:`n"
        $profiles | ForEach-Object { Write-Host "    $($_.Raw)" -ForegroundColor White }
        Write-Host ""

        $choice = Read-Host "  Use an existing profile? Enter index number, or press Enter to create new"

        if ($choice -ne '') {
            $selected = $profiles | Where-Object { $_.Index -eq [int]$choice }
            if (-not $selected) {
                Write-Fail "Invalid index: $choice"
                exit 1
            }
            pac auth select --index $selected.Index | Out-Null
            Write-Success "Auth profile [$($selected.Index)] selected."
            return
        }
    }
    else {
        Write-Info "No existing auth profiles found. Creating a new one."
    }

    # Create new profile
    Write-Host "`n  Cloud environments:" -ForegroundColor White
    Write-Host "    1) Commercial (default)"
    Write-Host "    2) GCC"
    Write-Host "    3) GCC High"
    Write-Host "    4) DoD"
    Write-Host ""

    $cloudChoice = Read-Host "  Select cloud (1-4, default 1)"
    # Store only the cloud value for safe array-based argument passing
    $cloudArg = switch ($cloudChoice) {
        '2' { 'UsGov' }
        '3' { 'UsGovHigh' }
        '4' { 'UsGovDod' }
        default { $null }
    }

    $profileName = Read-Host "  Enter a name for this profile (e.g. PPMF-GCCH-Dev)"
    if (-not $profileName) { $profileName = "profile-$(Get-Date -Format 'yyyyMMddHHmm')" }

    Write-Info "Opening browser for login..."
    # Use the call operator (&) with an argument array instead of Invoke-Expression to
    # prevent command injection from user-supplied input (OWASP A03 – Injection).
    $pacArgs = @('auth', 'create', '--name', $profileName)
    if ($cloudArg) { $pacArgs += '--cloud', $cloudArg }
    & pac @pacArgs

    $profiles   = Get-PacAuthProfiles
    $newProfile = $profiles | Where-Object { $_.Raw -like "*$profileName*" }
    if ($newProfile) {
        pac auth select --index $newProfile.Index | Out-Null
        Write-Success "Auth profile '$profileName' created and selected."
    }
    else {
        Write-Warn "Could not auto-select new profile. Run 'pac auth list' and select manually."
    }
}

function Format-PacEnvList {
    $raw = pac env list 2>&1
    $rows = @()
    foreach ($line in $raw) {
        if ($line -match '^\s*([^\t]+?)\s{2,}([0-9a-fA-F\-]{36})\s{2,}(\S+)\s{2,}(\S+)') {
            $rows += [PSCustomObject]@{
                Name = $Matches[1].Trim()
                ID   = $Matches[2].Trim()
                Type = $Matches[3].Trim()
                URL  = $Matches[4].Trim()
            }
        }
    }
    if ($rows.Count -gt 0) {
        $rows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
    } else {
        $raw | ForEach-Object { Write-Host "  $_" }
    }
}

function Format-PacSolutionList {
    $raw = pac solution list 2>&1
    $rows = @()
    foreach ($line in $raw) {
        if ($line -match '^\s*([^\t]+?)\s{2,}(\S+)\s{2,}([\d\.]+)\s*$') {
            $rows += [PSCustomObject]@{
                'Display Name'   = $Matches[1].Trim()
                'Unique Name'    = $Matches[2].Trim()
                'Version'        = $Matches[3].Trim()
            }
        }
    }
    if ($rows.Count -gt 0) {
        $rows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
    } else {
        $raw | ForEach-Object { Write-Host "  $_" }
    }
}

function Select-SourceEnvironment {
    Write-Header "Source Environment"

    $envId = Read-Host "  Enter source Environment ID (GUID), or press Enter to list environments"

    if ($envId -eq '') {
        Write-Info "Fetching environments (may take a moment)..."
        Format-PacEnvList
        Write-Host ""
        $envId = Read-Host "  Enter source Environment ID (GUID)"
    }

    if ($envId -notmatch '^[0-9a-fA-F\-]{36}$') {
        Write-Fail "Invalid Environment ID format. Expected a GUID."
        exit 1
    }

    Write-Success "Environment $envId will be targeted for export."
    return $envId
}

function Select-Solution {
    Write-Header "Solution Selection"

    if (-not $SolutionName) {
        $list = Read-Host "  Enter solution unique name, or press Enter to list solutions"
        if ($list -eq '') {
            Write-Info "Fetching solution list (may take a moment)..."
            Format-PacSolutionList
            Write-Host ""
            $script:SolutionName = Read-Host "  Enter the solution unique name to export"
        } else {
            $script:SolutionName = $list
        }
    }

    if (-not $SolutionName) {
        Write-Fail "No solution name provided."
        exit 1
    }

    Write-Success "Solution: $SolutionName"
}

function Invoke-Export {
    Write-Header "Exporting Solution"

    if (-not $OutputZip) {
        $default  = ".\$SolutionName.zip"
        # Avoid $input — it is a PowerShell automatic pipeline variable.
        $zipInput = Read-Host "  Output zip path (Enter for '$default')"
        $script:OutputZip = if ($zipInput) { $zipInput } else { $default }
    }

    $solutionType = if ($Managed) { 'Managed' } else {
        $choice = Read-Host "  Export type: (1) Unmanaged [default]  (2) Managed"
        if ($choice -eq '2') {
            $script:Managed = $true
            'Managed'
        }
        else { 'Unmanaged' }
    }

    Write-Info "Exporting '$SolutionName' ($solutionType) → '$OutputZip'..."

    # Use the call operator (&) with an argument array instead of Invoke-Expression to
    # prevent command injection from user-supplied names and paths (OWASP A03 – Injection).
    $pacArgs = @('solution', 'export', '--name', $SolutionName, '--path', $OutputZip, '--overwrite')
    if ($solutionType -eq 'Managed') { $pacArgs += '--managed' }
    & pac @pacArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "pac solution export failed."
        exit 1
    }

    $size = [math]::Round((Get-Item $OutputZip).Length / 1KB, 1)
    Write-Success "Exported: $OutputZip ($size KB, $solutionType)"
}

function Invoke-Unpack {
    Write-Header "Unpacking Solution"

    # Derive default unpack folder from the zip name (strip .zip extension)
    $defaultFolder = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName((Resolve-Path $OutputZip)),
        [System.IO.Path]::GetFileNameWithoutExtension($OutputZip)
    )

    $folderInput  = Read-Host "  Unpack folder (Enter for '$defaultFolder')"
    $unpackFolder = if ($folderInput) { $folderInput } else { $defaultFolder }

    Write-Info "Unpacking '$OutputZip' → '$unpackFolder'..."

    pac solution unpack --zipFile $OutputZip --folder $unpackFolder --allowDelete

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "pac solution unpack failed."
        exit 1
    }

    Write-Success "Unpacked to: $unpackFolder"
    Write-Info    "Folder is in PAC-unpacked format and can be committed to source control."
    Write-Info    "Use deploy.ps1 to repack and import — it will auto-detect the format."
}

# ── Gamification / Usage Statistics ──────────────────────────────────────────
#
#   WHAT  : Tracks run counts and cumulative runtime, then displays a fun stats
#           summary at the end of each successful run.
#   WHERE : Stats persist in a small JSON file at:
#               $env:LOCALAPPDATA\powerplatform-devtools\download-stats.json
#   HOW   : $ScriptStartTime is set in main before the core work begins.
#           Runtime is captured before Show-UsageStats is called, so the
#           gamification output never inflates the recorded elapsed time.
#   OFF   : Pass -NoStats at the command line, or permanently disable by setting:
#               $env:PPDEVTOOLS_NO_STATS = '1'
#           To remove entirely, delete these functions and the 3 lines in main
#           that reference $ScriptStartTime, $runtimeSec, and Show-UsageStats.
# ─────────────────────────────────────────────────────────────────────────────

function Get-UsageStats([string]$StatsFile) {
    <#
    .SYNOPSIS
        Reads persisted usage stats from a local JSON file.
    .OUTPUTS
        Hashtable with TotalRuns, TotalRuntimeSeconds, LastRun.
        Returns zeroed defaults if the file is absent or cannot be parsed.
    #>
    if (Test-Path $StatsFile) {
        try {
            $j = Get-Content $StatsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            return @{
                TotalRuns           = [double]$j.TotalRuns
                TotalRuntimeSeconds = [double]$j.TotalRuntimeSeconds
                LastRun             = [string]$j.LastRun
            }
        } catch { <# Fall through to defaults on corrupt file or missing keys #> }
    }
    return @{ TotalRuns = 0; TotalRuntimeSeconds = 0.0; LastRun = '' }
}

function Save-UsageStats([string]$StatsFile, [hashtable]$Stats) {
    <#
    .SYNOPSIS  Persists updated stats to JSON.  Non-fatal if the write fails.
    #>
    try {
        $dir = Split-Path $StatsFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Stats | ConvertTo-Json -Depth 3 | Set-Content $StatsFile -Encoding UTF8 -ErrorAction Stop
    } catch { <# Best-effort — stats failure does not affect script behaviour #> }
}

function Format-Duration([double]$Seconds) {
    <#
    .SYNOPSIS  Formats a duration in seconds as a concise "Xm Ys" string.
    #>
    $m = [math]::Floor($Seconds / 60)
    $s = [math]::Round($Seconds % 60)
    if ($m -gt 0) { return "${m}m ${s}s" } else { return "${s}s" }
}

function Show-UsageStats {
    <#
    .SYNOPSIS
        Updates stored run stats and renders a coloured summary to the console.
    .PARAMETER RuntimeSeconds
        Elapsed seconds for this execution.  Must be captured *before* calling
        this function so the display time is not counted in the recorded runtime.
    .PARAMETER StatsFile
        Absolute path to the JSON stats file for this script.
    .PARAMETER ManualMinutes
        Estimated minutes the equivalent action takes through the Maker Portal UI.
        Used to calculate time saved per run.
    .PARAMETER ActionLabel
        Short description of the manual action (shown in the stats output).
    #>
    param(
        [double] $RuntimeSeconds,
        [string] $StatsFile,
        [double] $ManualMinutes,
        [string] $ActionLabel
    )

    $stats                      = Get-UsageStats $StatsFile
    $stats.TotalRuns           += 1
    $stats.TotalRuntimeSeconds += $RuntimeSeconds
    $stats.LastRun              = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Save-UsageStats $StatsFile $stats

    $avgScriptSec  = $stats.TotalRuntimeSeconds / $stats.TotalRuns
    $manualSec     = $ManualMinutes * 60
    $savedThisRun  = [math]::Max(0, $manualSec - $RuntimeSeconds)
    $totalSavedSec = [math]::Max(0, ($manualSec * $stats.TotalRuns) - $stats.TotalRuntimeSeconds)
    $runWord       = if ($stats.TotalRuns -ne 1) { 'runs' } else { 'run' }
    $border        = '═' * 60

    Write-Host ""
    Write-Host "  $border"                                                                                             -ForegroundColor Magenta
    Write-Host "  🎮  Your Power Platform Dev Stats"                                                                  -ForegroundColor Magenta
    Write-Host "  $border"                                                                                             -ForegroundColor Magenta
    Write-Host ("  🚀  Run #{0} complete in {1}"                     -f $stats.TotalRuns, (Format-Duration $RuntimeSeconds)) -ForegroundColor Cyan
    Write-Host ("  ⏱   Avg script time      :  {0}"                 -f (Format-Duration $avgScriptSec))              -ForegroundColor Cyan
    Write-Host ("  🖱   Avg manual UI time   :  {0}  ({1})"         -f (Format-Duration $manualSec), $ActionLabel)   -ForegroundColor DarkYellow
    Write-Host ("  ⏳  Time saved this run   :  {0}"                 -f (Format-Duration $savedThisRun))              -ForegroundColor Green
    Write-Host ("  🏆  Total time saved      :  {0} across {1} {2}" -f (Format-Duration $totalSavedSec), $stats.TotalRuns, $runWord) -ForegroundColor Green
    Write-Host ""
    Write-Host ("  💡  Congrats! You've saved ~{0} using this script!" -f (Format-Duration $totalSavedSec))          -ForegroundColor Yellow
    Write-Host "  $border"                                                                                             -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Stats file  : $StatsFile"                                                                           -ForegroundColor DarkGray
    Write-Host "  To disable  : run with -NoStats, or set `$env:PPDEVTOOLS_NO_STATS = '1'"                           -ForegroundColor DarkGray
    Write-Host ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Host "`n  Power Platform Solution Download Script" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
$ScriptStartTime = Get-Date   # captured early so total interactive + processing time is recorded

Assert-PacCli
Select-AuthProfile
Select-SourceEnvironment
Select-Solution
Invoke-Export

# Prompt for unpack if not passed as a switch
if (-not $Unpack) {
    $unpackChoice = Read-Host "`n  Unpack solution into source-control folder? (y/N)"
    if ($unpackChoice -ieq 'y') { $Unpack = $true }
}

if ($Unpack) { Invoke-Unpack }

# ── Usage stats (runtime captured here so gamification display is excluded from the total) ──
$runtimeSec = ([datetime]::Now - $ScriptStartTime).TotalSeconds
if (-not $NoStats -and $env:PPDEVTOOLS_NO_STATS -ne '1') {
    # ManualMinutes = 8: estimated time to export a solution via the Maker Portal
    #   (navigate → Solutions → find solution → Export → select type → Next → Export → download zip)
    Show-UsageStats -RuntimeSeconds $runtimeSec `
                    -StatsFile      "$env:LOCALAPPDATA\powerplatform-devtools\download-stats.json" `
                    -ManualMinutes  8 `
                    -ActionLabel    'Solution Export via Maker Portal'
}

Write-Header "Complete"
Write-Success "Download finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

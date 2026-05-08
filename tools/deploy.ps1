#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive Power Platform solution packaging and deployment script.

.DESCRIPTION
    Guides the user through selecting a PAC CLI auth profile (or creating one),
    targeting an environment, packaging a solution folder, and importing it.
    Supports sovereign clouds (GCC, GCC High, DoD) via PAC auth profile configuration.

.USAGE
    .\deploy.ps1
    .\deploy.ps1 -SolutionFolder ".\MySolution" -OutputZip ".\MySolution.zip" -Managed

.PARAMETER SolutionFolder
    Path to the unpacked solution folder. Prompted interactively if omitted.

.PARAMETER OutputZip
    Path for the output .zip file. Defaults to <SolutionFolder>.zip if omitted.

.PARAMETER Managed
    Pack as a managed solution. Defaults to unmanaged.

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
    [string] $SolutionFolder,
    [string] $OutputZip,
    [switch] $Managed,
    # Pass -NoStats (or set $env:PPDEVTOOLS_NO_STATS = '1') to suppress the usage stats summary.
    [switch] $NoStats
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Load run-history module ───────────────────────────────────────────────────
$script:ModulePath = Join-Path $PSScriptRoot 'run-history.psm1'
if (Test-Path $script:ModulePath) {
    Import-Module $script:ModulePath -Force
} else {
    Write-Warning "run-history.psm1 not found — previous run history will not be available."
}

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
    # Returns array of profile objects parsed from 'pac auth list'
    $raw = pac auth list 2>&1
    $profiles = @()
    foreach ($line in $raw) {
        # Lines look like:  [1] PROFILE_NAME  user@domain  https://...
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
    <#
    .OUTPUTS  The selected or created profile name (string), or '' if unknown.
    #>
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
            # Extract just the profile name token from the raw line
            $profileName = if ($selected.Raw -match '\[\d+\]\s+(\S+)') { $Matches[1] } else { $selected.Raw }
            Write-Success "Auth profile [$($selected.Index)] selected."
            return $profileName
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

    $profileName = Read-Host "  Enter a name for this profile (e.g. PPMF-GCCH-Prod)"
    if (-not $profileName) { $profileName = "profile-$(Get-Date -Format 'yyyyMMddHHmm')" }

    Write-Info "Opening browser for login..."

    # Use the call operator (&) with an argument array instead of Invoke-Expression to
    # prevent command injection from user-supplied input (OWASP A03 – Injection).
    $pacArgs = @('auth', 'create', '--name', $profileName)
    if ($cloudArg) { $pacArgs += '--cloud', $cloudArg }
    & pac @pacArgs

    # Re-select the newly created profile by name
    $profiles = Get-PacAuthProfiles
    $newProfile = $profiles | Where-Object { $_.Raw -like "*$profileName*" }
    if ($newProfile) {
        pac auth select --index $newProfile.Index | Out-Null
        Write-Success "Auth profile '$profileName' created and selected."
    }
    else {
        Write-Warn "Could not auto-select new profile. Run 'pac auth list' and select manually."
    }
    return $profileName
}

function Format-PacEnvList {
    $raw = pac env list 2>&1
    $rows = @()
    foreach ($line in $raw) {
        # pac env list rows: Display Name  Environment ID  Type  URL
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
        # Fallback: print raw output if parsing yielded nothing
        $raw | ForEach-Object { Write-Host "  $_" }
    }
}

function Select-Environment {
    Write-Header "Target Environment"

    $envId = Read-Host "  Enter target Environment ID (GUID), or press Enter to list environments"

    if ($envId -eq '') {
        Write-Info "Fetching environments (may take a moment)..."
        Format-PacEnvList
        Write-Host ""
        $envId = Read-Host "  Enter target Environment ID (GUID)"
    }

    if ($envId -notmatch '^[0-9a-fA-F\-]{36}$') {
        Write-Fail "Invalid Environment ID format. Expected a GUID."
        exit 1
    }

    Write-Success "Environment $envId will be targeted for import."
    return $envId
}

function Resolve-SolutionFolder {
    if (-not $SolutionFolder) {
        $SolutionFolder = Read-Host "  Enter path to unpacked solution folder"
    }
    $SolutionFolder = $SolutionFolder.TrimEnd('\', '/')
    if (-not (Test-Path $SolutionFolder)) {
        Write-Fail "Solution folder not found: $SolutionFolder"
        exit 1
    }
    # Accept both raw export (solution.xml at root) and PAC-unpacked (Other\Solution.xml)
    $hasSolutionXml = (Test-Path (Join-Path $SolutionFolder 'solution.xml')) -or
                      (Test-Path (Join-Path $SolutionFolder 'Other\Solution.xml'))
    if (-not $hasSolutionXml) {
        Write-Fail "No solution.xml found in: $SolutionFolder. Is this a valid solution folder?"
        exit 1
    }
    Write-Success "Solution folder: $SolutionFolder"
    return $SolutionFolder
}

function Invoke-Pack([string]$FolderPath) {
    Write-Header "Packaging Solution"

    if (-not $OutputZip) {
        $default  = "$FolderPath.zip"
        # Avoid $input — it is a PowerShell automatic pipeline variable.
        $zipInput = Read-Host "  Output zip path (Enter for '$default')"
        $script:OutputZip = if ($zipInput) { $zipInput } else { $default }
    }

    # Detect which format the folder is in:
    #   PAC-unpacked : produced by 'pac solution unpack' — has Other\Customizations.xml
    #   Raw export   : produced by maker-portal export  — has customizations.xml at root
    $isPacUnpacked = Test-Path (Join-Path $FolderPath 'Other\Customizations.xml')

    if ($isPacUnpacked) {
        Write-Info "Detected PAC-unpacked format (Other\Customizations.xml). Using pac solution pack."

        $solutionType = if ($Managed) { 'Managed' } else {
            $choice = Read-Host "  Package type: (1) Unmanaged [default]  (2) Managed"
            if ($choice -eq '2') { 'Managed' } else { 'Unmanaged' }
        }

        Write-Info "Packing '$FolderPath' → '$OutputZip' ($solutionType)..."

        # Use the call operator (&) with an argument array instead of inline args to
        # prevent command injection from user-supplied paths (OWASP A03 – Injection).
        $pacArgs = @('solution', 'pack', '--folder', $FolderPath, '--zipFile', $OutputZip, '--packagetype', $solutionType)
        & pac @pacArgs

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "pac solution pack failed."
            exit 1
        }
    }
    else {
        Write-Info "Detected raw export format (customizations.xml at root). Using Compress-Archive."
        if ($Managed) { Write-Warn "-Managed flag is ignored for raw export format — solution type was fixed at export time." }

        Write-Info "Packing '$FolderPath' → '$OutputZip'..."
        Compress-Archive -Path "$FolderPath\*" -DestinationPath $OutputZip -Force
    }

    $size = [math]::Round((Get-Item $OutputZip).Length / 1KB, 1)
    Write-Success "Solution packed: $OutputZip ($size KB)"
}

function Invoke-Deploy([string]$EnvId) {
    Write-Header "Deploying Solution"

    # Import options
    $publish   = Read-Host "  Publish all customizations after import? (Y/n)"
    $overwrite = Read-Host "  Overwrite unmanaged customizations? (Y/n)"

    # Use the call operator (&) with an argument array instead of Invoke-Expression to
    # prevent command injection from user-supplied paths and IDs (OWASP A03 – Injection).
    $pacArgs = @('solution', 'import', '--path', $OutputZip, '--environment', $EnvId, '--activate-plugins')
    if ($publish   -ine 'n') { $pacArgs += '--publish-changes' }
    if ($overwrite -ine 'n') { $pacArgs += '--force-overwrite' }

    Write-Info "Importing '$OutputZip' to environment $EnvId..."
    & pac @pacArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "pac solution import failed."
        exit 1
    }

    Write-Success "Solution imported successfully."
    if ($publish -ine 'n') { Write-Success "Customizations published." }
}

# ── Gamification / Usage Statistics ──────────────────────────────────────────
#
#   WHAT  : Tracks run counts and cumulative runtime, then displays a fun stats
#           summary at the end of each successful run.
#   WHERE : Stats persist in a small JSON file at:
#               $env:LOCALAPPDATA\powerplatform-devtools\deploy-stats.json
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

Write-Host "`n  Power Platform Solution Deployment Script" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
$ScriptStartTime = Get-Date   # captured early so total interactive + processing time is recorded

Assert-PacCli

# ── Previous run history ──────────────────────────────────────────────────────
$authProfile    = ''
$envId          = ''
$usedPrevRun    = $false

if (Get-Command 'Get-SavedRunHistory' -ErrorAction SilentlyContinue) {
    $history = @(Get-SavedRunHistory -ScriptType 'deploy' -ScriptPath $PSCommandPath)
    if ($history.Count -gt 0) {
        Write-Host "`n  ℹ  Previous run configurations found." -ForegroundColor Cyan
        $selected = Select-SavedRun -History $history
        if ($selected) {
            $confirmed = Confirm-ReusedRun -Entry $selected -ScriptType 'deploy'
            if ($confirmed) {
                # Restore variables from saved entry
                $authProfile    = $selected.AuthProfile
                $envId          = $selected.EnvironmentId
                $SolutionFolder = $selected.SolutionFolder
                if ($selected.SolutionType -eq 'Managed') { $Managed = $true }

                # Apply saved auth profile selection
                if ($authProfile) {
                    $profiles   = Get-PacAuthProfiles
                    $match      = $profiles | Where-Object { $_.Raw -like "*$authProfile*" }
                    if ($match) {
                        pac auth select --index $match.Index | Out-Null
                        Write-Success "Auth profile '$authProfile' reselected."
                    } else {
                        Write-Warn "Saved auth profile '$authProfile' not found — please select manually."
                        $authProfile = Select-AuthProfile
                    }
                }

                # Validate restored solution folder still exists
                if ($SolutionFolder -and -not (Test-Path $SolutionFolder)) {
                    Write-Warn "Saved solution folder '$SolutionFolder' no longer exists — please re-enter."
                    $SolutionFolder = ''
                }

                $usedPrevRun = $true
            }
        }
    }
}

# ── Manual input for any values not restored from history ─────────────────────
if (-not $usedPrevRun -or -not $authProfile) {
    $authProfile = Select-AuthProfile
}
if (-not $usedPrevRun -or -not $envId) {
    $envId = Select-Environment
}
$SolutionFolder = Resolve-SolutionFolder
Invoke-Pack   -FolderPath $SolutionFolder
Invoke-Deploy -EnvId $envId

# ── Save successful run to history ────────────────────────────────────────────
if (Get-Command 'Save-RunHistory' -ErrorAction SilentlyContinue) {
    $solutionType = if ($Managed) { 'Managed' } else { 'Unmanaged' }
    Save-RunHistory -ScriptType 'deploy' -ScriptPath $PSCommandPath -Config @{
        AuthProfile    = $authProfile
        EnvironmentId  = $envId
        SolutionFolder = $SolutionFolder
        SolutionType   = $solutionType
        OutputZip      = $OutputZip
    }
}

# ── Usage stats (runtime captured here so gamification display is excluded from the total) ──
$runtimeSec = ([datetime]::Now - $ScriptStartTime).TotalSeconds
if (-not $NoStats -and $env:PPDEVTOOLS_NO_STATS -ne '1') {
    # ManualMinutes = 12: estimated time to import a solution via the Maker Portal
    #   (navigate → Solutions → Import solution → upload zip → review → Next → Import → wait → publish)
    Show-UsageStats -RuntimeSeconds $runtimeSec `
                    -StatsFile      "$env:LOCALAPPDATA\powerplatform-devtools\deploy-stats.json" `
                    -ManualMinutes  12 `
                    -ActionLabel    'Solution Import via Maker Portal'
}

Write-Header "Complete"
Write-Success "Deployment finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

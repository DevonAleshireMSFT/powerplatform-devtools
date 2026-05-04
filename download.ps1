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
    [switch] $Unpack
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

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Host "`n  Power Platform Solution Download Script" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray

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

Write-Header "Complete"
Write-Success "Download finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

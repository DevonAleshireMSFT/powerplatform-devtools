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
    [switch] $Managed
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

        pac solution pack `
            --folder      $FolderPath `
            --zipFile     $OutputZip  `
            --packagetype $solutionType

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

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Host "`n  Power Platform Solution Deployment Script" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray

Assert-PacCli
Select-AuthProfile
$envId          = Select-Environment
$SolutionFolder = Resolve-SolutionFolder
Invoke-Pack   -FolderPath $SolutionFolder
Invoke-Deploy -EnvId $envId

Write-Header "Complete"
Write-Success "Deployment finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

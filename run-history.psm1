#Requires -Version 7.0
<#
.SYNOPSIS
    Shared run-history module for powerplatform-devtools scripts.

.DESCRIPTION
    Provides functions to save, retrieve, display, and manage a history of
    previous deploy/download runs.  Each entry is scoped by script type,
    script path, and solution path so that different projects never
    accidentally reuse the wrong configuration.

    History is stored at:
        $env:LOCALAPPDATA\powerplatform-devtools\run-history.json

    SECURITY NOTES
    ──────────────
    • Only non-secret metadata is persisted: PAC auth profile names,
      environment IDs (GUIDs), solution names, and file paths.
    • No tokens, passwords, or credentials are ever stored.
    • Auth profile names are display identifiers managed by PAC CLI — they
      carry no inherent privilege.
    • Environment IDs (GUIDs) identify a Dataverse environment but grant no
      access on their own.  They are equivalent to configuration metadata.
    • The history file is written under the current user's LOCALAPPDATA, which
      is user-scoped and not readable by other OS accounts on shared machines.
    • Consumers should still treat environment IDs as internal identifiers and
      avoid sharing the history file outside the machine.

    SAFE DEFAULTS
    ─────────────
    • History entries expire after ExpiryHours (default 24).  Expired entries
      are never presented for reuse.
    • At most MaxEntries (default 10) entries per scope key are retained.
    • A confirmation prompt is always shown before executing a reused config.
    • All values passed to PAC CLI are delivered via argument arrays, never
      via Invoke-Expression or string interpolation into shell commands.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ─────────────────────────────────────────────────────────────────

$script:HistoryFile = Join-Path $env:LOCALAPPDATA 'powerplatform-devtools\run-history.json'

# ── Internal helpers ──────────────────────────────────────────────────────────

function script:Get-HistoryStore {
    <#
    .SYNOPSIS  Reads the JSON history store from disk.  Returns a typed object.
    #>
    if (Test-Path $script:HistoryFile) {
        try {
            $raw = Get-Content $script:HistoryFile -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            return $obj
        } catch {
            # Corrupt file — return empty store (will be overwritten on next save)
        }
    }
    # Return a default store structure
    return [PSCustomObject]@{
        Settings = [PSCustomObject]@{
            ExpiryHours = 24
            MaxEntries  = 10
        }
        Entries = @()
    }
}

function script:Save-HistoryStore([PSCustomObject]$Store) {
    <#
    .SYNOPSIS  Writes the history store to disk.  Non-fatal if it fails.
    #>
    try {
        $dir = Split-Path $script:HistoryFile -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $Store | ConvertTo-Json -Depth 6 | Set-Content $script:HistoryFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "  ⚠  Could not save run history: $_"
    }
}

function script:Get-ScopeKey([string]$ScriptType, [string]$ScriptPath, [string]$SolutionPath) {
    <#
    .SYNOPSIS
        Returns a normalised string key that scopes history to a specific
        (script type, script location, solution location) combination.

        Using absolute resolved paths prevents cross-project contamination
        when scripts are run from different working directories.
    #>
    $absScript   = (Resolve-Path $ScriptPath   -ErrorAction SilentlyContinue)?.Path ?? $ScriptPath
    $absSolution = if ($SolutionPath) {
        (Resolve-Path $SolutionPath -ErrorAction SilentlyContinue)?.Path ?? $SolutionPath
    } else { '' }

    return "$ScriptType|$absScript|$absSolution"
}

function script:Test-EntryExpired([PSCustomObject]$Entry, [int]$ExpiryHours) {
    <#
    .SYNOPSIS  Returns $true if the entry is older than ExpiryHours.
    #>
    try {
        $saved = [datetime]::Parse($Entry.Timestamp)
        return ([datetime]::UtcNow - $saved).TotalHours -gt $ExpiryHours
    } catch {
        return $true   # Unparseable timestamp — treat as expired
    }
}

# ── Public API ────────────────────────────────────────────────────────────────

function Get-SavedRunHistory {
    <#
    .SYNOPSIS
        Returns saved (non-expired) run history entries for the given scope.

    .PARAMETER ScriptType
        'deploy' or 'download' — used as part of the scope key.

    .PARAMETER ScriptPath
        Absolute or relative path to the calling script file.

    .PARAMETER SolutionPath
        Absolute or relative path to the solution folder (deploy) or output
        path (download).  May be empty for download when not yet known.

    .PARAMETER IncludeExpired
        If specified, also returns expired entries (useful for diagnostics).

    .OUTPUTS
        Array of PSCustomObject entries, newest first.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptType,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$SolutionPath    = '',
        [switch]$IncludeExpired
    )

    $store    = script:Get-HistoryStore
    $key      = script:Get-ScopeKey $ScriptType $ScriptPath $SolutionPath
    $expiry   = [int]$store.Settings.ExpiryHours

    $entries = @($store.Entries) | Where-Object { $_.ScopeKey -eq $key }

    if (-not $IncludeExpired) {
        $entries = $entries | Where-Object { -not (script:Test-EntryExpired $_ $expiry) }
    }

    return @($entries | Sort-Object Timestamp -Descending)
}

function Save-RunHistory {
    <#
    .SYNOPSIS
        Appends a new run entry to the history store.

    .PARAMETER ScriptType
        'deploy' or 'download'.

    .PARAMETER ScriptPath
        Path to the calling script.

    .PARAMETER Config
        Hashtable of run configuration values to persist.
        For deploy : AuthProfile, EnvironmentId, SolutionFolder, SolutionType
        For download: AuthProfile, EnvironmentId, SolutionName, OutputZip, Unpack

    .NOTES
        Only the most recent MaxEntries entries per scope are retained.
        Older entries beyond that limit are pruned automatically.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptType,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $store      = script:Get-HistoryStore
    $solutionPath = if ($Config.ContainsKey('SolutionFolder')) { $Config.SolutionFolder }
                    elseif ($Config.ContainsKey('OutputZip'))  { $Config.OutputZip }
                    else                                       { '' }

    $key        = script:Get-ScopeKey $ScriptType $ScriptPath $solutionPath
    $maxEntries = [int]$store.Settings.MaxEntries

    $newEntry = [PSCustomObject]([ordered]@{
        ScopeKey     = $key
        ScriptType   = $ScriptType
        Timestamp    = (Get-Date).ToUniversalTime().ToString('o')  # ISO 8601 UTC
        AuthProfile  = [string]($Config.AuthProfile  ?? '')
        EnvironmentId = [string]($Config.EnvironmentId ?? '')
        SolutionName = [string]($Config.SolutionName  ?? '')
        SolutionFolder = [string]($Config.SolutionFolder ?? '')
        SolutionType  = [string]($Config.SolutionType   ?? '')
        OutputZip    = [string]($Config.OutputZip    ?? '')
        Unpack       = [bool]  ($Config.Unpack        ?? $false)
    })

    # Prepend new entry; keep only MaxEntries for this scope
    $existing  = @($store.Entries) | Where-Object { $_.ScopeKey -ne $key }
    $scoped    = @($store.Entries) | Where-Object { $_.ScopeKey -eq $key }
    $trimmed   = @($scoped | Sort-Object Timestamp -Descending | Select-Object -First ($maxEntries - 1))
    $store.Entries = @($newEntry) + $trimmed + $existing

    script:Save-HistoryStore $store
}

function Select-SavedRun {
    <#
    .SYNOPSIS
        Interactively prompts the user to pick a saved run from history.

    .PARAMETER History
        Array of entries returned by Get-SavedRunHistory.

    .OUTPUTS
        The selected entry PSCustomObject, or $null if the user declines.
    #>
    param(
        [Parameter(Mandatory)][array]$History
    )

    Write-Host ""
    Write-Host "  $('─' * 60)" -ForegroundColor DarkGray
    Write-Host "  Previous Run Configurations" -ForegroundColor Cyan
    Write-Host "  $('─' * 60)" -ForegroundColor DarkGray
    Write-Host ""

    for ($i = 0; $i -lt $History.Count; $i++) {
        $e       = $History[$i]
        $ts      = [datetime]::Parse($e.Timestamp).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        $age     = [math]::Round(([datetime]::UtcNow - [datetime]::Parse($e.Timestamp)).TotalMinutes)
        $ageText = if ($age -lt 60) { "${age}m ago" } else { "$([math]::Round($age/60,1))h ago" }

        Write-Host ("  [{0}]  {1}  ({2})" -f ($i + 1), $ts, $ageText) -ForegroundColor White

        if ($e.AuthProfile)   { Write-Host ("        Auth Profile  : {0}" -f $e.AuthProfile)   -ForegroundColor Gray }
        if ($e.EnvironmentId) { Write-Host ("        Environment   : {0}" -f $e.EnvironmentId) -ForegroundColor Gray }
        if ($e.SolutionName)  { Write-Host ("        Solution      : {0}" -f $e.SolutionName)  -ForegroundColor Gray }
        if ($e.SolutionFolder){ Write-Host ("        Source Folder : {0}" -f $e.SolutionFolder)-ForegroundColor Gray }
        if ($e.SolutionType)  { Write-Host ("        Type          : {0}" -f $e.SolutionType)  -ForegroundColor Gray }
        if ($e.OutputZip)     { Write-Host ("        Output Zip    : {0}" -f $e.OutputZip)     -ForegroundColor Gray }
        if ($e.ScriptType -eq 'download' -and $e.Unpack) {
                                Write-Host  "        Unpack        : Yes"                        -ForegroundColor Gray }
        Write-Host ""
    }

    $choice = Read-Host "  Enter a number to reuse a configuration, or press Enter to enter details manually"

    if ($choice -eq '') { return $null }

    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $History.Count) {
        Write-Host "  ⚠  Invalid selection — entering details manually." -ForegroundColor Yellow
        return $null
    }

    return $History[$idx - 1]
}

function Confirm-ReusedRun {
    <#
    .SYNOPSIS
        Shows a summary of the selected run and asks the user to confirm.

    .PARAMETER Entry
        The selected history entry.

    .PARAMETER ScriptType
        'deploy' or 'download' — used in the confirmation message.

    .OUTPUTS
        $true if confirmed, $false if the user declines.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Entry,
        [Parameter(Mandatory)][string]$ScriptType
    )

    $action = if ($ScriptType -eq 'deploy') { 'DEPLOY TO' } else { 'DOWNLOAD FROM' }

    Write-Host ""
    Write-Host "  $('═' * 60)" -ForegroundColor Yellow
    Write-Host "  ⚠   CONFIRM REUSED CONFIGURATION" -ForegroundColor Yellow
    Write-Host "  $('═' * 60)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  Action        : {0}" -f $action) -ForegroundColor White
    if ($Entry.AuthProfile)    { Write-Host ("  Auth Profile  : {0}" -f $Entry.AuthProfile)   -ForegroundColor White }
    if ($Entry.EnvironmentId)  { Write-Host ("  Environment   : {0}" -f $Entry.EnvironmentId) -ForegroundColor Yellow }
    if ($Entry.SolutionName)   { Write-Host ("  Solution      : {0}" -f $Entry.SolutionName)  -ForegroundColor White }
    if ($Entry.SolutionFolder) { Write-Host ("  Source Folder : {0}" -f $Entry.SolutionFolder)-ForegroundColor White }
    if ($Entry.SolutionType)   { Write-Host ("  Type          : {0}" -f $Entry.SolutionType)  -ForegroundColor White }
    if ($Entry.OutputZip)      { Write-Host ("  Output Zip    : {0}" -f $Entry.OutputZip)     -ForegroundColor White }
    if ($ScriptType -eq 'download' -and $Entry.Unpack) {
                                 Write-Host  "  Unpack        : Yes"                           -ForegroundColor White }
    Write-Host ""
    Write-Host "  ⚠   Verify the Environment ID above before proceeding." -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "  Are you sure you want to run using this configuration? (y/N)"
    return $confirm -ieq 'y'
}

function Clear-SavedRunHistory {
    <#
    .SYNOPSIS
        Removes all or scoped run history entries.

    .PARAMETER ScriptType
        If provided, only entries matching this script type are removed.

    .PARAMETER ScriptPath
        If provided (with ScriptType), only entries for this script path are removed.

    .PARAMETER All
        Clears the entire history store (all scripts, all scopes).
    #>
    param(
        [string]$ScriptType  = '',
        [string]$ScriptPath  = '',
        [switch]$All
    )

    $store = script:Get-HistoryStore

    if ($All) {
        $store.Entries = @()
        script:Save-HistoryStore $store
        Write-Host "  ✔  All run history cleared." -ForegroundColor Green
        return
    }

    if ($ScriptType -and $ScriptPath) {
        $key          = script:Get-ScopeKey $ScriptType $ScriptPath ''
        # Remove all entries whose ScopeKey starts with the script-level prefix
        $prefix       = "$ScriptType|$((Resolve-Path $ScriptPath -ErrorAction SilentlyContinue)?.Path ?? $ScriptPath)|"
        $store.Entries = @($store.Entries | Where-Object { -not $_.ScopeKey.StartsWith($prefix) })
        script:Save-HistoryStore $store
        Write-Host "  ✔  Run history cleared for $ScriptType ($ScriptPath)." -ForegroundColor Green
        return
    }

    Write-Host "  ⚠  Specify -All to clear everything, or provide -ScriptType and -ScriptPath to clear a specific scope." -ForegroundColor Yellow
}

function Set-RunHistorySettings {
    <#
    .SYNOPSIS
        Updates the global run-history settings.

    .PARAMETER ExpiryHours
        Number of hours after which a saved run is considered expired and will
        not be offered for reuse.  Minimum 1, maximum 168 (one week).
        Default: 24

    .PARAMETER MaxEntries
        Maximum number of history entries to retain per scope.
        Minimum 1, maximum 50.  Default: 10

    .EXAMPLE
        Set-RunHistorySettings -ExpiryHours 8 -MaxEntries 5
    #>
    param(
        [ValidateRange(1, 168)][int]$ExpiryHours = 0,
        [ValidateRange(1,  50)][int]$MaxEntries  = 0
    )

    $store = script:Get-HistoryStore

    if ($ExpiryHours -gt 0) { $store.Settings.ExpiryHours = $ExpiryHours }
    if ($MaxEntries  -gt 0) { $store.Settings.MaxEntries  = $MaxEntries  }

    script:Save-HistoryStore $store
    Write-Host ("  ✔  Settings updated — ExpiryHours: {0}, MaxEntries: {1}" -f $store.Settings.ExpiryHours, $store.Settings.MaxEntries) -ForegroundColor Green
}

Export-ModuleMember -Function @(
    'Get-SavedRunHistory'
    'Save-RunHistory'
    'Select-SavedRun'
    'Confirm-ReusedRun'
    'Clear-SavedRunHistory'
    'Set-RunHistorySettings'
)

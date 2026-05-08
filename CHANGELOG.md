# Changelog

All notable changes to this project are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).  
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.2.0] — 2026-05-08

### Added

- **Run history module** — new `run-history.psm1` shared module that saves previous run configurations and offers them for reuse on subsequent runs.
  - History is scoped by script type, absolute script path, and absolute solution path, preventing cross-project contamination.
  - Stored in `%LOCALAPPDATA%\powerplatform-devtools\run-history.json` (user-scoped, no secrets stored — profile names, environment IDs, solution names, and file paths only).
  - Configurable expiry (`ExpiryHours`, default `24`) and entry limit (`MaxEntries`, default `10`) persisted in the JSON settings block.
  - New public functions: `Get-SavedRunHistory`, `Save-RunHistory`, `Select-SavedRun`, `Confirm-ReusedRun`, `Clear-SavedRunHistory`, `Set-RunHistorySettings`.
- **Previous run prompt** (`deploy.ps1`, `download.ps1`) — before prompting for inputs, each script checks for saved non-expired configurations and displays a numbered menu for selection.
- **Confirmation guard** — a highlighted confirmation prompt (with the Environment ID in yellow) must be explicitly accepted before executing a reused configuration. Manual-entry runs do not require a separate confirmation.
- **Auth profile reselection** — when restoring a saved run, the matching PAC CLI auth profile is automatically reselected by index. Falls back to manual selection if the profile no longer exists.
- **Solution folder validation** (`deploy.ps1`) — if the saved solution folder path no longer exists on disk, the user is warned and prompted to re-enter it.
- `run-history.psm1` imported at startup in both scripts; if the file is missing, a warning is shown and the scripts continue without history support.

### Changed

- `Select-AuthProfile` (both scripts) now returns the selected or created profile name so it can be captured for history storage.
- README updated: version badge bumped to `1.2.0`, `run-history.psm1` added to the Overview table, new **Run History** section (flow, storage, configuration, utility functions, expiry guidance), A03 security note extended, A05 section expanded to cover all three local JSON files.

### Security

- No secrets, tokens, or credentials are stored in `run-history.json`. Only display-level metadata is persisted (PAC auth profile name, environment GUID, solution name, file paths).
- All history JSON reads use typed casts; a corrupt or tampered file yields safe defaults.
- History file contents are never passed to `Invoke-Expression`, shell commands, or any PAC CLI call as constructed strings.
- All existing `& pac @pacArgs` argument-array mitigations preserved; `run-history.psm1` makes no PAC CLI calls directly.

---

## [1.1.0] — 2026-05-07

### Added

- **Gamification / Usage Statistics feature** (`download.ps1`, `deploy.ps1`)
  - Tracks total run count and cumulative script runtime across sessions, persisted to a local JSON file (`%LOCALAPPDATA%\powerplatform-devtools\*.json`).
  - Calculates average script time, estimated manual UI time, time saved per run, and total cumulative time saved.
  - Displays a fun, coloured stats summary panel at the end of each successful run.
  - New `-NoStats` switch parameter on both scripts to suppress the summary for a single run.
  - Supports permanent opt-out via `$env:PPDEVTOOLS_NO_STATS = '1'`.
  - New helper functions: `Get-UsageStats`, `Save-UsageStats`, `Format-Duration`, `Show-UsageStats` — fully decoupled from main script logic.
  - Runtime is captured before the stats block so gamification output is never counted in the elapsed time calculation.

### Fixed

- **Security (OWASP A03 – Injection)**: `Invoke-Unpack` in `download.ps1` converted `pac solution unpack` from inline argument splatting to `& pac @pacArgs` argument array, consistent with all other PAC CLI calls in the file.
- **Security (OWASP A03 – Injection)**: `Invoke-Pack` in `deploy.ps1` converted `pac solution pack` from inline argument splatting to `& pac @pacArgs` argument array, consistent with all other PAC CLI calls in the file.

### Changed

- `download.ps1` and `deploy.ps1` — main block now sets `$ScriptStartTime` at startup.
- README updated with new **Usage Stats & Gamification** section, screenshots, parameter table updates (`-NoStats`), version badge, and fully rewritten **Security Considerations** section covering OWASP A01, A03, A04, A05, and scope/limitations.
- Added `CHANGELOG.md`.

---

## [1.0.0] — 2026-04-01

### Added

- `download.ps1` — Interactive Power Platform solution export script.
  - PAC CLI auth profile selection / creation with sovereign cloud support (Commercial, GCC, GCC High, DoD).
  - Interactive source environment and solution selection.
  - Unmanaged and managed export.
  - Optional unpack into source-control-friendly folder structure via `pac solution unpack`.
- `deploy.ps1` — Interactive Power Platform solution pack and import script.
  - PAC CLI auth profile selection / creation with sovereign cloud support.
  - Auto-detection of PAC-unpacked vs raw-export solution folder format.
  - Pack via `pac solution pack` (PAC-unpacked) or `Compress-Archive` (raw export).
  - Import with configurable publish and overwrite options.
- Injection-safe PAC CLI invocation using PowerShell call operator (`&`) with argument arrays throughout (OWASP A03).
- Environment ID GUID validation before use.
- `README.md` with full usage guide, security considerations, and AI disclosure.
- `LICENSE` (MIT).
- `.gitignore` excluding PAC auth profiles, `.env` files, and exported solution zips.

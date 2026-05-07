# Changelog

All notable changes to this project are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).  
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

### Changed

- `download.ps1` and `deploy.ps1` — main block now sets `$ScriptStartTime` at startup.
- README updated with new **Usage Stats & Gamification** section, screenshots, parameter table updates (`-NoStats`), and version badge.
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

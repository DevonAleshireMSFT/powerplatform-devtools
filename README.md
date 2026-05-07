# powerplatform-devtools

![Version](https://img.shields.io/badge/version-1.1.0-blue) ![PowerShell](https://img.shields.io/badge/PowerShell-7.0%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green)

Interactive PowerShell scripts for managing Power Platform solution deployments via the PAC CLI. Supports exporting, unpacking, packing, and importing solutions across Commercial, GCC, GCC High, and DoD cloud environments.

---

## Overview

This repository contains two standalone PowerShell 7 scripts designed to streamline Power Platform ALM (Application Lifecycle Management) workflows:

| Script | Purpose |
|---|---|
| `download.ps1` | Export a solution from a source environment and optionally unpack it into a source-control-friendly folder structure |
| `deploy.ps1` | Pack an unpacked (or raw-export) solution folder into a `.zip` file and import it into a target environment |

Both scripts are fully interactive — they guide you through authentication, environment selection, and all required options at runtime. Parameters are also available for scripted/CI use.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **PowerShell 7.0+** | `pwsh` must be on your PATH. [Download](https://aka.ms/powershell) |
| **PAC CLI** | Power Apps CLI must be installed and on your PATH. [Install guide](https://aka.ms/PowerAppsCLI) |
| **Power Platform role** | System Customizer or System Administrator on the target/source environment |
| **Azure AD / Entra ID account** | Used for interactive browser-based login via PAC auth profiles |

Verify your setup before running:

```powershell
pwsh --version    # 7.0 or higher
pac --version     # any recent version
```

---

## Usage Guide

### download.ps1 — Export a solution

**Fully interactive (recommended for first-time use):**

```powershell
.\download.ps1
```

The script will prompt you to:
1. Select or create a PAC CLI auth profile (browser login)
2. Select the source environment (list or enter a GUID)
3. Select the solution to export (list or enter the unique name)
4. Choose the output `.zip` path
5. Choose Unmanaged or Managed export
6. Optionally unpack the solution into a folder for source control

**With parameters:**

```powershell
# Export only
.\download.ps1 -SolutionName "MySolution" -OutputZip ".\MySolution.zip"

# Export managed solution
.\download.ps1 -SolutionName "MySolution" -OutputZip ".\MySolution_managed.zip" -Managed

# Export and unpack for source control in one step
.\download.ps1 -SolutionName "MySolution" -OutputZip ".\MySolution.zip" -Unpack
```

---

### deploy.ps1 — Pack and import a solution

**Fully interactive:**

```powershell
.\deploy.ps1
```

The script will prompt you to:
1. Select or create a PAC CLI auth profile (browser login)
2. Select the target environment (list or enter a GUID)
3. Provide the path to the solution folder
4. Choose the output `.zip` path
5. Choose publish and overwrite options

**With parameters:**

```powershell
# Pack from an unpacked folder and deploy
.\deploy.ps1 -SolutionFolder ".\MySolution"

# Specify output zip and deploy as managed
.\deploy.ps1 -SolutionFolder ".\MySolution" -OutputZip ".\MySolution.zip" -Managed
```

---

## Configuration

### Script Parameters

#### `download.ps1`

| Parameter | Type | Description |
|---|---|---|
| `-SolutionName` | `string` | Unique name of the solution to export. Prompted interactively if omitted. |
| `-OutputZip` | `string` | Output path for the exported `.zip`. Defaults to `.\<SolutionName>.zip`. |
| `-Managed` | `switch` | Export as a managed solution. Defaults to unmanaged. |
| `-Unpack` | `switch` | Unpack the exported zip into a folder after export. |
| `-NoStats` | `switch` | Suppress the usage stats summary for this run. |

#### `deploy.ps1`

| Parameter | Type | Description |
|---|---|---|
| `-SolutionFolder` | `string` | Path to the unpacked solution folder. Prompted interactively if omitted. |
| `-OutputZip` | `string` | Output path for the packed `.zip`. Defaults to `<SolutionFolder>.zip`. |
| `-Managed` | `switch` | Pack as a managed solution. Defaults to unmanaged. |
| `-NoStats` | `switch` | Suppress the usage stats summary for this run. |

---

## Usage Stats & Gamification

Both scripts include a lightweight, opt-out stats feature that tracks how much time you are saving compared to doing the same action manually through the Maker Portal.

After each successful run you'll see a coloured summary like this:

**download.ps1**

![Download stats output](docs/images/stats-download.png)

**deploy.ps1**

![Deploy stats output](docs/images/stats-deploy.png)

### What is tracked

| Metric | How it's calculated |
|---|---|
| **Total runs** | Incremented by 1 each execution |
| **Avg script time** | Cumulative runtime ÷ total runs |
| **Avg manual UI time** | Fixed baseline: 8 min (export), 12 min (import) — see assumptions below |
| **Time saved this run** | Manual baseline − this run's elapsed time |
| **Total time saved** | (Baseline × total runs) − cumulative script runtime |

Runtime is captured _before_ the stats block runs, so the display output is never counted in the calculation.

### Storage

Stats are stored as small JSON files in your local user profile:

```
%LOCALAPPDATA%\powerplatform-devtools\download-stats.json
%LOCALAPPDATA%\powerplatform-devtools\deploy-stats.json
```

The directory is created automatically on first run. No data is sent anywhere — everything stays local.

### Disabling the stats feature

The feature is **enabled by default**. To turn it off:

| Method | How |
|---|---|
| **Per-run** | Pass `-NoStats` flag: `.\ download.ps1 -NoStats` |
| **Permanently (current session)** | `$env:PPDEVTOOLS_NO_STATS = '1'` |
| **Permanently (all sessions)** | Add `$env:PPDEVTOOLS_NO_STATS = '1'` to your PowerShell profile (`$PROFILE`) |
| **Remove entirely** | Delete the `# ── Gamification / Usage Statistics ──` block and the 3 lines in `main` that reference `$ScriptStartTime`, `$runtimeSec`, and `Show-UsageStats` |

### Manual UI time assumptions

| Script | Baseline | Steps included in estimate |
|---|---|---|
| `download.ps1` | **8 minutes** | Navigate to make.powerapps.com → Solutions → locate solution → Export → choose type → Next → Export → wait → download zip |
| `deploy.ps1` | **12 minutes** | Navigate → Solutions → Import Solution → upload zip → review summary → Next → Import → wait for async job → publish customizations |

These are conservative estimates for a typical mid-size solution. Complex solutions or slow tenants will take longer, so actual savings are usually higher.

---

### Sovereign Cloud Configuration

Both scripts support sovereign cloud environments via PAC auth profiles. When creating a new profile, select the appropriate cloud:

| Option | PAC CLI Cloud Flag | Use Case |
|---|---|---|
| 1 — Commercial | _(default)_ | Standard commercial tenants |
| 2 — GCC | `UsGov` | US Government Community Cloud |
| 3 — GCC High | `UsGovHigh` | GCC High (ITAR/DoD contractors) |
| 4 — DoD | `UsGovDod` | Department of Defense |

Auth profiles are stored locally by the PAC CLI and persist between sessions. Use `pac auth list` to view saved profiles.

---

## Technical Details

### Authentication Flow

Both scripts use `pac auth` profiles for authentication:
- If profiles already exist, the user is prompted to select one by index.
- If no profiles exist (or the user opts to create a new one), the script calls `pac auth create`, which opens a browser for interactive login.
- Profiles are stored and managed entirely by the PAC CLI, not by these scripts.

### Solution Format Detection (`deploy.ps1`)

`deploy.ps1` auto-detects the format of the solution folder to determine how to pack it:

| Format | Detection Criteria | Pack Method |
|---|---|---|
| **PAC-unpacked** | `Other\Customizations.xml` present | `pac solution pack` |
| **Raw export** | `customizations.xml` at root (maker-portal export) | `Compress-Archive` |

### Typical ALM Workflow

```
Source Environment                     Target Environment
       │                                        │
  download.ps1  ──(export + unpack)──▶  Git repo  ──(pack + import)──▶  deploy.ps1
```

1. Run `download.ps1` to export and unpack the solution from the source environment.
2. Commit the unpacked folder to source control.
3. Run `deploy.ps1` on the unpacked folder to pack and import into the target environment.

---

## Security Considerations

### Authentication
- These scripts use **interactive browser-based login** via the PAC CLI. No credentials, tokens, or passwords are stored in the scripts or passed as parameters.
- PAC CLI auth profiles are stored in the local user profile (`~/.pac/`) by the PAC CLI itself, not by these scripts. Treat that directory with appropriate filesystem permissions.

### Command Execution
- All PAC CLI commands are invoked using PowerShell's **call operator (`&`) with argument arrays**, rather than `Invoke-Expression`. This prevents command injection from user-supplied inputs such as solution names, profile names, or file paths (OWASP A03 – Injection).

### No Secrets in Source Control
- The `.gitignore` in this repository excludes PAC auth profiles, `.env` files, credential files, and exported solution zips. Review `.gitignore` before committing to ensure sensitive artefacts are not accidentally tracked.

### Principle of Least Privilege
- Use an account with the **minimum required role** on each environment (System Customizer is sufficient for most operations; System Administrator is required for some import options). Avoid using global admin credentials for routine deployments.

### Limitations and Assumptions
- These scripts are designed for **interactive use by trusted operators**. They are not hardened for use in multi-tenant SaaS scenarios or against adversarial input from untrusted sources.
- Environment IDs (GUIDs) are validated with a regex pattern before use. Solution names and file paths are passed directly to the PAC CLI, which performs its own validation.
- The scripts require PowerShell 7+ and PAC CLI to be installed on the machine running them. Ensure your environment meets these requirements before running in a CI/CD pipeline.

### Reporting Issues
If you discover a security concern, please open a GitHub issue or contact the repository maintainers directly rather than posting sensitive details publicly.

---

## AI Disclosure

The scripts, security review, and documentation in this repository were generated with the assistance of **[GitHub Copilot](https://github.com/features/copilot)** (Claude Sonnet 4.6 model, via GitHub Copilot Pro). All output was reviewed by a human before publication.

Users should apply the same due diligence they would to any third-party code — review the scripts before running them in your environment.

---

## License

This project is licensed under the [MIT License](LICENSE). The software is provided **"as is"**, without warranty of any kind. Use in production environments is at your own risk — always test in a non-production environment first.

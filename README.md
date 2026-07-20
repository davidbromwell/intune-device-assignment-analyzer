# Intune Device Policy and Assignment Analyzer

## Purpose

This sanitized, read-only engineering sample contains no tenant IDs, company prefixes, internal URLs, or organization-specific paths. Graph tools use delegated interactive authentication. The account picker opens in the browser or Windows authentication broker. Device-code authentication is intentionally not used.

## Requirements

- Windows PowerShell 5.1, 64-bit
- Microsoft.Graph.Authentication for Graph-based tools
- An Intune role that permits the requested read operations
- Consent for the delegated scopes listed below
- `IntuneToolkit.Common.psm1` (the shared module), expected at `..\Shared\IntuneToolkit.Common.psm1` relative to this script's own folder. Keep the toolkit's folder structure intact when copying scripts elsewhere.

## Delegated permissions

- `DeviceManagementManagedDevices.Read.All`
- `DeviceManagementConfiguration.Read.All`
- `DeviceManagementApps.Read.All`
- `DeviceManagementServiceConfig.Read.All`
- `Group.Read.All`
- `Directory.Read.All`
- `User.Read.All`

## Usage

```powershell
.\Get-IntuneDevicePolicyAssignment.ps1 -DeviceName "DEMO-LAPTOP-001"
```

Optional: override the default output location.

```powershell
.\Get-IntuneDevicePolicyAssignment.ps1 -DeviceName "DEMO-LAPTOP-001" -OutputRoot "C:\Reports"
```

A companion diagnostic script, `Diagnose-ToolkitDevice.ps1`, is included for troubleshooting only. It looks up a single device and prints the raw type and shape of what the shared module's Graph helpers return, without Strict Mode enabled, so it will not itself fail on a missing or unexpected property. It writes nothing to disk and is not part of the reporting output.

```powershell
.\Diagnose-ToolkitDevice.ps1 -DeviceName "DEMO-LAPTOP-001"
```

## What it checks

For the named device, the script resolves:

- The managed device record (most recently synced match, if more than one device shares the name)
- The device's primary user(s)
- The device's Entra ID object and its full transitive group membership
- The primary user's transitive group membership
- Every device configuration profile, Settings Catalog / endpoint security policy, compliance policy, and application in the tenant, along with their assignments

Each assignment is then resolved against the device's and user's actual group memberships to produce a plain-language match basis: All devices, All users, device group membership, primary-user group membership, matching exclusion, or no direct match identified.

## Output

Four CSVs are written to the output folder for each run:

- `DeviceSummary.csv`: the device record (OS, version, compliance state, last sync, primary user(s))
- `DeviceGroups.csv`: every Entra ID group the device is a transitive member of
- `PrimaryUserGroups.csv`: every group the primary user is a transitive member of
- `Assignments.csv`: every configuration, policy, and app in the tenant, with intent, target type, matching group, and the plain-language match basis for this device

Output is written beneath the current user's Documents folder unless `-OutputRoot` is supplied. The Autopilot collector defaults to a folder on the current user's Desktop. No company-specific path is hard coded.

## Authentication behavior

The shared module calls `Connect-MgGraph -Scopes <scopes> -ContextScope Process -NoWelcome`. It disconnects any existing Graph context first and then opens interactive account selection. Do not add `-UseDeviceAuthentication`.

On long runs, a delegated token can expire mid-execution and trigger a second, silent-then-interactive sign-in. If that second sign-in fails in the browser with an error such as `AADSTS90015: Requested query string is too long`, this is a known Windows Web Account Manager (WAM) broker issue, not a script fault. Close the sign-in window, close the PowerShell session entirely, and re-run from a fresh window. The script fetches assignments in bulk (`$expand=assignments`) specifically to keep total run time well under typical token lifetimes and make this scenario unlikely.

## Performance and reliability notes

- Graph collection responses are unwrapped and paginated automatically (`value` plus `@odata.nextLink`) rather than assumed to be a single page.
- Assignments are retrieved with `$expand=assignments` where supported, so most tenants complete without one Graph call per object. If an endpoint does not support the expand, the script falls back automatically to a per-object assignment call for just the affected category.
- Progress is written to the console per category (item counts) and per object (`Write-Progress`) during assignment retrieval, so a long-running fetch (large app catalogs in particular) is visibly active rather than silent.
- Optional assignment target fields that Graph omits rather than sends as null (for example, group or collection identifiers that only apply to certain target types) are backfilled with documented defaults before evaluation, so a filterless or non-group assignment does not fail processing.

## Important limitations

- Assignment applicability is an engineering inference, not Intune's final policy engine result.
- Filters, exclusions, user-versus-device context, licensing, applicability rules, and service-side processing can change the effective result.
- Large tenants can require substantial time and Graph requests when group membership expansion is enabled.
- This solution uses selected Microsoft Graph beta endpoints. Test before production use and review changes to the API.

## Sanitization

Sample data uses fictional devices, groups, users, IDs, and application names. Do not publish real exports. Review logs and CSVs before sharing them outside your organization.

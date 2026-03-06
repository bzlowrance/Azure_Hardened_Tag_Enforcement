# Test Validation Guide

End-to-end workflow for provisioning Azure infrastructure, deploying tag enforcement policies, simulating non-compliant tags, and validating that Azure Policy auto-corrects them.

## Prerequisites

- **PowerShell 7+** with the Az module installed:
  ```powershell
  Install-Module Az -Scope CurrentUser
  ```
- **Required sub-modules:** `Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Subscription`
- **Authenticated session:** `Connect-AzAccount`
- **Permissions:**
  - Management Group Contributor on the tenant root (to create / delete management groups)
  - Resource Policy Contributor + Tag Contributor on the management group scope
  - If creating a new subscription: permission on the billing account

## Configuration (.env)

All scripts read from a shared `.env` file at the repository root. Key variables:

| Variable | Description | Example |
|---|---|---|
| `MANAGEMENT_GROUP_ID` | Name of the management group to create / target | `hardened-tags-mg` |
| `INITIATIVE_NAME` | Policy initiative name | `tag-enforcement-initiative` |
| `ASSIGNMENT_NAME` | Policy assignment name | `tag-enforcement-assignment` |
| `ASSIGNMENT_PARAMETERS_FILE` | Path to the parameters JSON (relative to repo root) | `assignment-parameters.json` |
| `ASSIGNMENT_LOCATION` | Region for the policy assignment managed identity | `eastus` |
| `STAGING_SUBSCRIPTION_ID` | `CREATE_NEW` to provision a fresh subscription, or an existing subscription GUID | `CREATE_NEW` |
| `STAGING_SUBSCRIPTION_NAME` | Display name for the new subscription (used only with `CREATE_NEW`) | `tag-validation-test` |
| `STAGING_BILLING_ACCOUNT_NAME` | Billing account — auto-detected from current login if blank | |
| `STAGING_BILLING_PROFILE_NAME` | Billing profile — auto-detected from current login if blank | |
| `STAGING_INVOICE_SECTION_NAME` | Invoice section — auto-detected from current login if blank | |
| `STAGING_LOCATION` | Azure region for staging resources | `eastus` |
| `STAGING_RG_PREFIX` | Optional prefix applied to every resource group name | |
| `STAGING_RESOURCE_GROUPS` | Comma-separated list of resource groups to create | `rg-dev,rg-shared,...` |
| `POLICY_DEF_OWNER` | Policy definition name for the Owner tag | `enforce-tag-owner` |
| `POLICY_DEF_COSTCODE` | Policy definition name for the CostCode tag | `enforce-tag-costcode` |
| `POLICY_DEF_BUSINESSUNIT` | Policy definition name for the BusinessUnit tag | `enforce-tag-businessunit` |

### Subscription Options

**Option A — Create a new subscription (`STAGING_SUBSCRIPTION_ID=CREATE_NEW`):**
A brand-new DevTest subscription is provisioned using the billing fields in `.env`. On teardown the subscription is cancelled and the management group is deleted.

**Option B — Use an existing subscription (provide a GUID):**
The existing subscription is moved under the test management group. Its original parent management group is recorded in `.staging-state.json`. On teardown the subscription is moved back to its original parent and the test management group is deleted. The subscription itself is **not** cancelled.

## Execution Order

Run the scripts from the `scripts/` directory in the order below.

### 1. Stage Test Infrastructure — `Stage_Test_Infrastructure.ps1`

Creates all Azure resources needed for the test:
1. Creates the management group (if it doesn't exist).
2. Creates or resolves the subscription (depending on `.env`).
3. Moves the subscription under the management group (prompts for confirmation).
4. Creates the resource groups listed in `STAGING_RESOURCE_GROUPS`.
5. Creates lightweight Storage Accounts per resource group and per resource-level override key — **without any tags**.

**Parameters:** None.

### 2. Deploy Tag Policies — `Deploy_Tag_Policies.ps1`

Deploys the three Azure Policy definitions, the initiative, and the assignment:
1. Creates/updates the Owner, CostCode, and BusinessUnit policy definitions.
2. Creates/updates the initiative that bundles them.
3. Creates/updates the policy assignment with the parameters from `assignment-parameters.json`.
4. Triggers a remediation task for each policy in the initiative.

**Parameters:**

| Parameter | Description |
|---|---|
| `-SkipRemediation` | Skip triggering remediation tasks after deployment. |

### 3. Validate Tag Enforcement — `Validate_Tag_Enforcement.ps1`

Scans every resource and compares tag values against the expected values from the assignment parameters file, using three-tier resolution:
1. **Resource-level override** (e.g. `ownerResourceOverrides."rg-dev/storagename"`)
2. **Resource-group override** (e.g. `ownerOverrides."rg-dev"`)
3. **Default value** (e.g. `defaultOwner`)

Outputs a summary table of compliant vs non-compliant resources.

**Parameters:**

| Parameter | Description |
|---|---|
| `-SubscriptionId` | Limit scan to a single subscription. If omitted, all subscriptions under the management group are scanned. |
| `-ExportCsv <path>` | Export non-compliant resources to a CSV file. |

### 4. Modify Tags (Apply Bad Tags) — `Modify_Tags.ps1`

Applies deliberately non-compliant tag values to every resource to simulate manual tampering:

| Tag | Bad Value Applied |
|---|---|
| Owner | `UNAUTHORIZED-OWNER` |
| CostCode | `INVALID-CC-0000` |
| BusinessUnit | `WRONG-DEPARTMENT` |

After running this script, wait for the Azure Policy remediation cycle (or trigger one manually), then run the Validate script again to confirm the policy auto-corrected all tags.

**Parameters:**

| Parameter | Description |
|---|---|
| `-WhatIf` | Preview changes without applying them. |
| `-SubscriptionId` | Limit to a single subscription. If omitted, all subscriptions under the management group are processed. |

### 5. Destroy Test Infrastructure — `Destroy_Test_Infrastructure.ps1`

Tears down everything in reverse order. Each destructive step prompts for confirmation:
1. Removes the policy assignment.
2. Removes the initiative.
3. Removes the three policy definitions.
4. Deletes all staging resource groups (parallel).
5. **If `CREATE_NEW`**: cancels the subscription. **If existing GUID**: moves the subscription back to its original parent management group (read from `.staging-state.json`).
6. Deletes the test management group.

**Parameters:**

| Parameter | Description |
|---|---|
| `-SkipPolicyCleanup` | Skip removal of the policy assignment, initiative, and definitions (steps 1-3). |
| `-SkipResourceGroups` | Skip removal of resource groups (step 4). |
| `-SkipSubscription` | Skip subscription cleanup and management group deletion (steps 5-6). |
| `-Force` | Suppress the top-level confirmation prompt. Individual move/delete confirmations still apply. |

## Typical Test Run

```powershell
cd scripts

# 1. Create infrastructure (no tags)
.\Stage_Test_Infrastructure.ps1

# 2. Deploy policies and trigger remediation
.\Deploy_Tag_Policies.ps1

# 3. Validate — all new resources should now have correct tags applied by policy
.\Validate_Tag_Enforcement.ps1

# 4. Tamper with the tags
.\Modify_Tags.ps1

# 5. Wait for policy remediation (~15 minutes) or trigger manually, then validate again
.\Validate_Tag_Enforcement.ps1

# 6. Tear down
.\Destroy_Test_Infrastructure.ps1
```

## State File

When an existing subscription is moved under the test management group (Option B), the staging script writes `.staging-state.json` to the repo root. This file records the subscription's original parent so the destroy script can move it back. Example:

```json
{
  "OriginalParentMG": "my-original-mg",
  "SubscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

This file is automatically cleaned up by the destroy script after the subscription is moved back.

## Tag Resolution Logic

The policies use a three-tier resolution to determine the correct tag value for each resource:

```
Resource-level override  →  RG-level override  →  Default value
```

Override maps are defined in `assignment-parameters.json`:
- `ownerResourceOverrides` / `costCodeResourceOverrides` / `businessUnitResourceOverrides` — keyed by `"resourceGroupName/resourceName"`
- `ownerOverrides` / `costCodeOverrides` / `businessUnitOverrides` — keyed by resource group name
- `defaultOwner` / `defaultCostCode` / `defaultBusinessUnit` — fallback values

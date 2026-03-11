# Azure Hardened Tag Enforcement — Single Assignment with Per-RG and Per-Resource Overrides

Enforces three mandatory tags (**Owner**, **CostCode**, **BusinessUnit**) on all **resources and resource groups** under a management group. Each tag supports three resolution levels — a **default value**, **per-resource-group overrides**, and **per-resource overrides** — all within **one policy assignment**.

## How it works

Each policy uses nested ARM `if(contains(...))` expressions with three-tier priority:

```
if resourceGroup/resourceName is a key in the resource override map
  → use the resource override value
else if resourceGroup is a key in the RG override map
  → use the RG override value
else
  → use the default value
```

Tags are **strictly enforced** — if someone changes or removes a tag, the policy corrects it on the next evaluation.

```mermaid
graph LR
    MG["🏢 Management Group<br/>ONE ASSIGNMENT"]

    subgraph params ["📋 Assignment Parameters"]
        direction TB
        P1["defaultOwner = TeamAlpha"]
        P2["ownerOverrides =<br/>rg-dev: DevOpsTeam"]
        P3["ownerResourceOverrides =<br/>rg-dev/vm-special-01: PlatformTeam"]
    end

    subgraph rgProd ["📦 rg-production"]
        direction TB
        ProdNote["Uses default"]
        R1["vm-prod-01<br/>Owner = TeamAlpha"]
        R2["storage-01<br/>Owner = TeamAlpha"]
    end

    subgraph rgDev ["📦 rg-dev"]
        direction TB
        DevNote["RG override applied"]
        R3["vm-dev-02<br/>Owner = DevOpsTeam"]
        R4["storage-02<br/>Owner = DevOpsTeam"]
        R5["vm-special-01<br/>Owner = PlatformTeam<br/>⚡ resource override"]
    end

    MG --- params
    MG --> rgProd
    MG --> rgDev

    style MG fill:#4A90D9,stroke:#2C5F8A,color:#fff,stroke-width:2px
    style params fill:#F5F5F5,stroke:#B0BEC5,stroke-dasharray:5 5
    style P1 fill:#E8F5E9,stroke:#66BB6A,color:#1B5E20
    style P2 fill:#FFF3E0,stroke:#FFA726,color:#E65100
    style P3 fill:#FCE4EC,stroke:#EF5350,color:#B71C1C
    style rgProd fill:#E3F2FD,stroke:#42A5F5,color:#0D47A1
    style R1 fill:#BBDEFB,stroke:#42A5F5,color:#0D47A1
    style R2 fill:#BBDEFB,stroke:#42A5F5,color:#0D47A1
    style rgDev fill:#FFF8E1,stroke:#FFB300,color:#E65100
    style R3 fill:#FFE082,stroke:#FFB300,color:#E65100
    style R4 fill:#FFE082,stroke:#FFB300,color:#E65100
    style R5 fill:#EF9A9A,stroke:#EF5350,color:#B71C1C
    style ProdNote fill:none,stroke:none,color:#42A5F5
    style DevNote fill:none,stroke:none,color:#FFB300
```

## Repository structure

```
Azure_Hardened_Tag_Enforcement/
├── policies/
│   ├── enforce-tag-owner.json          # Policy — Owner (resources)
│   ├── enforce-tag-costcode.json       # Policy — CostCode (resources)
│   ├── enforce-tag-businessunit.json   # Policy — BusinessUnit (resources)
│   ├── enforce-rg-tag-owner.json       # Policy — Owner (resource groups)
│   ├── enforce-rg-tag-costcode.json    # Policy — CostCode (resource groups)
│   ├── enforce-rg-tag-businessunit.json# Policy — BusinessUnit (resource groups)
│   └── initiative.json                 # Initiative bundling all six
├── scripts/
│   ├── Stage_Test_Infrastructure.ps1  # Create MG, subscription, RGs, resources
│   ├── Deploy_Tag_Policies.ps1        # Deploy definitions, initiative, assignment
│   ├── Deploy_Auto_Remediation.ps1    # Set up recurring auto-remediation
│   ├── AutoRemediation_Runbook.ps1    # Automation Account runbook (imported automatically)
│   ├── Validate_Tag_Enforcement.ps1   # Scan resources and report compliance
│   ├── Modify_Tags.ps1               # Apply non-compliant tags to test policy
│   └── Destroy_Test_Infrastructure.ps1# Tear down all test resources
├── .env                               # Configuration for all scripts
├── assignment-parameters.json         # Assignment parameter values
├── TestValidationReadme.md            # End-to-end test & validation guide
└── README.md
```

## Automated test & validation

A full suite of PowerShell scripts is included to provision infrastructure, deploy the policies, simulate tag tampering, and validate that the policies auto-correct. See **[TestValidationReadme.md](TestValidationReadme.md)** for the complete walkthrough, script parameters, and configuration options.

## Import into the Azure Portal

### Step 1 — Create the 6 policy definitions

For each file (`enforce-tag-owner.json`, `enforce-tag-costcode.json`, `enforce-tag-businessunit.json`, `enforce-rg-tag-owner.json`, `enforce-rg-tag-costcode.json`, `enforce-rg-tag-businessunit.json`):

1. **Azure Portal > Policy > Definitions > + Policy definition**
2. **Definition location**: your management group
3. **Name**: match the filename (e.g. `enforce-tag-owner`)
4. **Category**: `Tags`
5. Paste the `policyRule` and `parameters` content
6. Save

The `enforce-tag-*` policies use `mode: Indexed` and target resources inside RGs. The `enforce-rg-tag-*` policies use `mode: All` and target resource groups themselves.

### Step 2 — Create the initiative

1. **Policy > Definitions > + Initiative definition**
2. **Definition location**: same management group
3. Add the 6 policies from Step 1
4. In `initiative.json`, replace **`<MG_ID>`** with your management group ID
5. Save

### Step 3 — Assign the initiative

1. **Policy > Assignments > Assign initiative**
2. **Scope**: your management group
3. Set parameters:

   | Parameter | Example value |
   |---|---|
   | Default Owner | `TeamAlpha` |
   | Owner RG overrides | `{"rg-dev": "DevOpsTeam", "rg-shared": "SecurityTeam"}` |
   | Owner resource overrides | `{"rg-dev/vm-special-01": "PlatformTeam"}` |
   | Default CostCode | `CC-1000` |
   | CostCode RG overrides | `{"rg-dev": "CC-2000-DEV", "rg-staging": "CC-3000-STG"}` |
   | CostCode resource overrides | `{"rg-prod/vm-billing-01": "CC-9000-BILLING"}` |
   | Default BusinessUnit | `Engineering` |
   | BusinessUnit RG overrides | `{"rg-finance": "Finance", "rg-marketing": "Marketing"}` |
   | BusinessUnit resource overrides | `{"rg-prod/vm-billing-01": "Finance"}` |

4. **Remediation** tab: check **Create a remediation task**
5. Save

See `assignment-parameters.json` for a complete example.

### Adding or changing an override

Just **edit the assignment parameters** — no new policies or assignments needed:

1. **Policy > Assignments** > click the assignment
2. **Edit assignment > Parameters**
3. Add, change, or remove entries in the override Object
4. Save
5. Run a remediation task to apply changes to existing resources

## How the policy rules work

### Resource policies (`enforce-tag-*`, mode: Indexed)

The policy condition checks four cases (using Owner as an example):

1. **Tag is missing** → fire (add it)
2. **Resource key (`rgName/resourceName`) is in the resource override map AND tag differs** → fire (correct it)
3. **Resource key is NOT in resource map, RG is in the RG override map AND tag differs** → fire (correct it)
4. **Neither map has an entry AND tag differs from the default** → fire (correct it)

The modify operation resolves the correct value using nested `if()`:

```json
"value": "[if(
  contains(parameters('tagValuesByResource'), concat(resourceGroup().name, '/', field('name'))),
  parameters('tagValuesByResource')[concat(resourceGroup().name, '/', field('name'))],
  if(
    contains(parameters('tagValuesByResourceGroup'), resourceGroup().name),
    parameters('tagValuesByResourceGroup')[resourceGroup().name],
    parameters('defaultTagValue')
  )
)]"
```

### Resource group policies (`enforce-rg-tag-*`, mode: All)

These use `field('name')` (the RG's own name) instead of `resourceGroup()` (which is not available when evaluating an RG). The condition checks two cases:

1. **Tag is missing** → fire (add it)
2. **RG name is in the RG override map AND tag differs, OR tag differs from the default** → fire (correct it)

```json
"value": "[if(
  contains(parameters('tagValuesByResourceGroup'), field('name')),
  parameters('tagValuesByResourceGroup')[field('name')],
  parameters('defaultTagValue')
)]"
```

### Override key format

| Level | Key format | Example |
|---|---|---|
| Resource group | `<rgName>` | `"rg-dev"` |
| Specific resource | `<rgName>/<resourceName>` | `"rg-dev/vm-special-01"` |

The resource name is the ARM `field('name')` value — the short name of the resource, not the full resource ID.

## Scope

- **Resource policies** (`enforce-tag-*`): `mode: Indexed` — applies to all taggable resources inside resource groups. Uses `resourceGroup().name` for RG lookup and `concat(resourceGroup().name, '/', field('name'))` for resource lookup.
- **Resource group policies** (`enforce-rg-tag-*`): `mode: All` with a type filter for `Microsoft.Resources/subscriptions/resourceGroups` — applies to the RGs themselves. Uses `field('name')` for RG lookup (since `resourceGroup()` is not available when evaluating an RG).

Both sets of policies share the same RG override maps and default values via the initiative, so there is only **one assignment** to manage.

## Default tag values

| Tag | Default |
|---|---|
| Owner | `TeamAlpha` |
| CostCode | `CC-1000` |
| BusinessUnit | `Engineering` |

## Remediating existing resources

After creating or updating the assignment, run a remediation task:

1. **Policy > Remediation > + Remediation task**
2. Select the assignment
3. Choose the policies to remediate
4. Submit

## Auto-remediation

The `modify` policy effect automatically corrects tags on resource **create and update** operations. For pre-existing resources (or resources that haven't been modified since the policy was assigned), a recurring remediation job ensures they are caught.

`Deploy_Auto_Remediation.ps1` creates:

| Resource | Purpose |
|---|---|
| **Azure Automation Account** | Hosts the runbook with a system-assigned managed identity |
| **PowerShell Runbook** | Triggers policy evaluation scan + remediation tasks |
| **Recurring Schedule** | Runs every N hours (configurable via `AUTOMATION_SCHEDULE_HOURS` in `.env`) |
| **Role Assignments** | Resource Policy Contributor + Tag Contributor at MG scope |

### Setup

```powershell
# After deploying the policies:
.\scripts\Deploy_Auto_Remediation.ps1
```

### Configuration (`.env`)

| Variable | Default | Description |
|---|---|---|
| `AUTOMATION_ACCOUNT_NAME` | `aa-tag-remediation` | Name of the Automation Account |
| `AUTOMATION_RG_NAME` | `rg-tag-automation` | Resource group for the Automation Account |
| `AUTOMATION_SCHEDULE_HOURS` | `6` | How often the runbook runs (in hours) |

### How it works

1. Authenticates using the Automation Account's managed identity
2. Triggers a policy evaluation scan on each subscription under the management group
3. Creates remediation tasks for all six tag policies (3 resource + 3 resource group)
4. Repeats on the configured schedule

## Cleanup

```bash
MG=hardened-tags-mg

# Remove assignment
az policy assignment delete \
  --name <ASSIGNMENT_NAME> \
  --scope "/providers/Microsoft.Management/managementGroups/$MG"

# Remove initiative
az policy set-definition delete \
  --name tag-enforcement-initiative \
  --management-group $MG

# Remove definitions (resources + resource groups)
for tag in owner costcode businessunit; do
  az policy definition delete --name "enforce-tag-${tag}" --management-group $MG
  az policy definition delete --name "enforce-rg-tag-${tag}" --management-group $MG
done
```

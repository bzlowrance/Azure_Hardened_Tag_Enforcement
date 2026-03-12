<#
.SYNOPSIS
    Deploys an Azure Automation Account with a recurring runbook that
    auto-remediates tag enforcement policy violations.

.DESCRIPTION
    1. Creates a resource group for the Automation Account (if needed).
    2. Creates the Automation Account with a system-assigned managed identity.
    3. Creates a custom RBAC role with explicit PolicyInsights permissions and
       assigns it along with Tag Contributor and Reader at the management group scope.
    4. Imports required Az modules into the Automation Account.
    5. Imports the remediation runbook.
    6. Creates Automation variables for configuration.
    7. Creates a recurring schedule and links it to the runbook.

    Reads configuration from ../.env.

.NOTES
    Prerequisites:
      - Az PowerShell module (Install-Module Az)
      - Logged in via Connect-AzAccount
      - Sufficient permissions on the target management group and subscription
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Load .env ───────────────────────────────────────────
$repoRoot = Split-Path -Parent $PSScriptRoot
$envFile  = Join-Path $repoRoot '.env'

if (-not (Test-Path $envFile)) {
    Write-Error "Missing .env file at $envFile. Copy .env.example and fill in your values."
}

$envVars = @{}
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $envVars[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
}

$MG_ID           = $envVars['MANAGEMENT_GROUP_ID']
$INITIATIVE_NAME = $envVars['INITIATIVE_NAME']
$ASSIGNMENT_NAME = $envVars['ASSIGNMENT_NAME']
$locationPref    = $envVars['ASSIGNMENT_LOCATION']

# Normalize management group id to avoid hidden whitespace/formatting artifacts
$rawMgId = [string]$MG_ID
$MG_ID = (($rawMgId -replace '\s', '') -replace '[^A-Za-z0-9\-\._\(\)]', '').Trim()
if ([string]::IsNullOrWhiteSpace($MG_ID)) {
    Write-Error "MANAGEMENT_GROUP_ID is empty/invalid after normalization. Raw value: '$rawMgId'"
}
if ($MG_ID -ne $rawMgId.Trim()) {
    Write-Warning "MANAGEMENT_GROUP_ID normalized from '$rawMgId' to '$MG_ID'."
}

$AUTOMATION_ACCOUNT_NAME = $envVars['AUTOMATION_ACCOUNT_NAME']
$AUTOMATION_RG_NAME      = $envVars['AUTOMATION_RG_NAME']
$AUTOMATION_SCHEDULE_HR  = $envVars['AUTOMATION_SCHEDULE_HOURS']

if (-not $AUTOMATION_ACCOUNT_NAME) { $AUTOMATION_ACCOUNT_NAME = 'aa-tag-remediation' }
if (-not $AUTOMATION_RG_NAME)      { $AUTOMATION_RG_NAME = 'rg-tag-automation' }
if (-not $AUTOMATION_SCHEDULE_HR)  { $AUTOMATION_SCHEDULE_HR = '6' }

$scheduleHours = [int]$AUTOMATION_SCHEDULE_HR

# ── Resolve Azure region ────────────────────────────────
function Resolve-AzureLocation {
    param([string]$Preferred)

    $available = @(Get-AzLocation | Select-Object -ExpandProperty Location)
    if ($available.Count -eq 0) {
        Write-Error "No Azure locations available for the current subscription."
    }

    if ($Preferred -and $Preferred -ne 'AUTO') {
        if ($available -contains $Preferred) { return $Preferred }
        Write-Warning "Configured location '$Preferred' is not available."
    }

    $existingRgs = @(Get-AzResourceGroup -ErrorAction SilentlyContinue)
    if ($existingRgs.Count -gt 0) {
        $topRegion = $existingRgs |
            Group-Object Location |
            Sort-Object Count -Descending |
            Select-Object -First 1
        if ($topRegion -and ($available -contains $topRegion.Name)) {
            return $topRegion.Name
        }
    }

    $preferred = @(
        'eastus2', 'eastus', 'westus2', 'centralus',
        'usgovvirginia', 'usgovarizona', 'usgovtexas',
        'westeurope', 'northeurope', 'uksouth',
        'canadacentral', 'australiaeast', 'japaneast'
    )
    foreach ($r in $preferred) {
        if ($available -contains $r) { return $r }
    }

    return $available[0]
}

# Ensure context is set to a subscription under the MG
$mgSubs = @(Get-AzManagementGroupSubscription -GroupId $MG_ID -ErrorAction SilentlyContinue)
if ($mgSubs.Count -eq 0) {
    Write-Error "No subscriptions found under management group '$MG_ID'. Deploy the management group and subscription first."
}

$targetSubId = ($mgSubs[0].Id -split '/')[-1]
Set-AzContext -SubscriptionId $targetSubId -Force | Out-Null

$LOCATION = Resolve-AzureLocation -Preferred $locationPref

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Auto-Remediation Setup" -ForegroundColor Cyan
Write-Host " Subscription     : $targetSubId" -ForegroundColor Cyan
Write-Host " Location          : $LOCATION" -ForegroundColor Cyan
Write-Host " Management Group  : $MG_ID" -ForegroundColor Cyan
Write-Host " Automation Acct   : $AUTOMATION_ACCOUNT_NAME" -ForegroundColor Cyan
Write-Host " Resource Group    : $AUTOMATION_RG_NAME" -ForegroundColor Cyan
Write-Host " Schedule          : Every $scheduleHours hour(s)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

# ── Step 1: Create resource group ───────────────────────
Write-Host "`n[1/6] Creating resource group '$AUTOMATION_RG_NAME'..." -ForegroundColor Yellow
$rg = Get-AzResourceGroup -Name $AUTOMATION_RG_NAME -ErrorAction SilentlyContinue
if (-not $rg) {
    New-AzResourceGroup -Name $AUTOMATION_RG_NAME -Location $LOCATION | Out-Null
    Write-Host "  Created." -ForegroundColor Green
} else {
    Write-Host "  Already exists." -ForegroundColor Green
}

# ── Step 2: Create Automation Account ───────────────────
Write-Host "`n[2/6] Creating Automation Account '$AUTOMATION_ACCOUNT_NAME'..." -ForegroundColor Yellow
$aa = Get-AzAutomationAccount -ResourceGroupName $AUTOMATION_RG_NAME -Name $AUTOMATION_ACCOUNT_NAME -ErrorAction SilentlyContinue
if (-not $aa) {
    New-AzAutomationAccount `
        -ResourceGroupName     $AUTOMATION_RG_NAME `
        -Name                  $AUTOMATION_ACCOUNT_NAME `
        -Location              $LOCATION `
        -AssignSystemIdentity | Out-Null
    Write-Host "  Created with system-assigned managed identity." -ForegroundColor Green
    # Wait for identity to provision
    Start-Sleep -Seconds 10
    $aa = Get-AzAutomationAccount -ResourceGroupName $AUTOMATION_RG_NAME -Name $AUTOMATION_ACCOUNT_NAME
} else {
    Write-Host "  Already exists." -ForegroundColor Green
}

# Retrieve the managed identity principal ID
$aaResource = Get-AzResource -ResourceGroupName $AUTOMATION_RG_NAME -Name $AUTOMATION_ACCOUNT_NAME -ResourceType 'Microsoft.Automation/automationAccounts' -ExpandProperties
$principalId = $aaResource.Identity.PrincipalId
if (-not $principalId) {
    Write-Error "Automation Account managed identity not found. Ensure system-assigned identity is enabled."
}
Write-Host "  Managed Identity Principal: $principalId" -ForegroundColor DarkGray

# ── Step 3: Create custom role and grant roles at MG scope ──
Write-Host "`n[3/6] Creating custom role and granting roles to managed identity..." -ForegroundColor Yellow
$mgScope = "/providers/Microsoft.Management/managementGroups/$MG_ID"

# ── 3a: Create (or update) custom role for policy remediation ──
$customRoleName = "Tag Enforcement Remediation Operator"
$customRoleDefId = [guid]::NewGuid().ToString()

# Check if the custom role already exists under this MG
$existingRolePath = "${mgScope}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&`$filter=roleName eq '${customRoleName}'"
$existingRoleResp = Invoke-AzRestMethod -Path $existingRolePath -Method GET -ErrorAction SilentlyContinue
$existingRole = $null
if ($existingRoleResp.StatusCode -eq 200) {
    $existingRoles = ($existingRoleResp.Content | ConvertFrom-Json).value
    if ($existingRoles.Count -gt 0) {
        $existingRole = $existingRoles[0]
        $customRoleDefId = $existingRole.name
        Write-Host "  Custom role already exists (ID: $customRoleDefId). Updating..." -ForegroundColor DarkGray
    }
}

$customRoleBody = @{
    properties = @{
        roleName    = $customRoleName
        description = 'Custom role for tag enforcement auto-remediation. Grants explicit PolicyInsights, Authorization read, and resource management permissions at MG scope.'
        type        = 'CustomRole'
        permissions = @(
            @{
                actions = @(
                    'Microsoft.PolicyInsights/remediations/write',
                    'Microsoft.PolicyInsights/remediations/read',
                    'Microsoft.PolicyInsights/remediations/delete',
                    'Microsoft.PolicyInsights/policyStates/*',
                    'Microsoft.PolicyInsights/policyTrackedResources/*',
                    'Microsoft.Authorization/policyAssignments/read',
                    'Microsoft.Authorization/policyDefinitions/read',
                    'Microsoft.Authorization/policySetDefinitions/read',
                    'Microsoft.Management/managementGroups/read',
                    'Microsoft.Resources/deployments/*',
                    'Microsoft.Resources/subscriptions/read',
                    'Microsoft.Resources/subscriptions/resourceGroups/read'
                )
                notActions    = @()
                dataActions   = @()
                notDataActions = @()
            }
        )
        assignableScopes = @(
            $mgScope
        )
    }
} | ConvertTo-Json -Depth 10

$roleDefPath = "${mgScope}/providers/Microsoft.Authorization/roleDefinitions/${customRoleDefId}?api-version=2022-04-01"
$roleDefResp = Invoke-AzRestMethod -Path $roleDefPath -Method PUT -Payload $customRoleBody -ErrorAction Stop
if ($roleDefResp.StatusCode -ge 200 -and $roleDefResp.StatusCode -lt 300) {
    Write-Host "  Custom role '$customRoleName' created/updated (ID: $customRoleDefId)." -ForegroundColor Green
} else {
    $errContent = $roleDefResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    $errMsg = if ($errContent -and $errContent.error) { $errContent.error.message } else { "HTTP $($roleDefResp.StatusCode)" }
    Write-Error "  Failed to create custom role: $errMsg"
}

# Wait for role definition to propagate
Write-Host "  Waiting 15 seconds for role definition to propagate..." -ForegroundColor DarkGray
Start-Sleep -Seconds 15

# ── 3b: Assign roles at MG scope ──
# Custom role for PolicyInsights remediation permissions
$customRoleFullId = "${mgScope}/providers/Microsoft.Authorization/roleDefinitions/${customRoleDefId}"
# Tag Contributor (allows modifying tags via policy remediation)
$tagContribRoleId = "4a9ae827-6dc8-4573-8ac7-8239d42aa03f"
# Reader (allows listing subscriptions under the MG for evaluation scans)
$readerRoleId     = "acdd72a7-3385-48ef-bd42-f606fba81ae7"

$rolesToAssign = @(
    @{ Name = 'Tag Enforcement Remediation Operator'; DefinitionId = $customRoleFullId; RoleId = $customRoleDefId },
    @{ Name = 'Tag Contributor';                      DefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$tagContribRoleId"; RoleId = $tagContribRoleId },
    @{ Name = 'Reader';                               DefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$readerRoleId"; RoleId = $readerRoleId }
)

# Remove stale assignments from prior Automation Account identities.
# Stale entries commonly show as principalType = Unknown after identity recreation.
Write-Host "  Cleaning up stale MG-scope role assignments for prior identities..." -ForegroundColor DarkGray
$roleIdSet = @{}
foreach ($role in $rolesToAssign) {
    $roleIdSet[$role.RoleId.ToLowerInvariant()] = $true
}

$existingAssignmentsPath = "${mgScope}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
$existingAssignmentsResp = Invoke-AzRestMethod -Path $existingAssignmentsPath -Method GET -ErrorAction Stop
if ($existingAssignmentsResp.StatusCode -eq 200) {
    $existingAssignments = @((($existingAssignmentsResp.Content | ConvertFrom-Json).value))
    foreach ($assignment in $existingAssignments) {
        $assignmentRoleId = (($assignment.properties.roleDefinitionId.TrimEnd('/') -split '/')[-1]).ToLowerInvariant()
        $assignmentPrincipalId = [string]$assignment.properties.principalId
        $assignmentPrincipalType = [string]$assignment.properties.principalType

        if ($roleIdSet.ContainsKey($assignmentRoleId) -and $assignmentPrincipalId -ne $principalId -and $assignmentPrincipalType -eq 'Unknown') {
            $deletePath = "$($assignment.id)?api-version=2022-04-01"
            $deleteResp = Invoke-AzRestMethod -Path $deletePath -Method DELETE -ErrorAction SilentlyContinue
            if ($deleteResp.StatusCode -ge 200 -and $deleteResp.StatusCode -lt 300) {
                Write-Host "  • Removed stale role assignment: $($assignment.name)" -ForegroundColor Green
            } else {
                $deleteErr = $deleteResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
                $deleteMsg = if ($deleteErr -and $deleteErr.error) { $deleteErr.error.message } else { "HTTP $($deleteResp.StatusCode)" }
                Write-Warning "  • Could not remove stale assignment '$($assignment.name)': $deleteMsg"
            }
        }
    }
}

$roleAssignmentFailures = @()

foreach ($role in $rolesToAssign) {
    $roleAssignmentId = [guid]::NewGuid().ToString()
    $roleAssignPath = "${mgScope}/providers/Microsoft.Authorization/roleAssignments/${roleAssignmentId}?api-version=2022-04-01"
    $roleAssignBody = @{
        properties = @{
            principalId      = $principalId
            roleDefinitionId = $role.DefinitionId
            principalType    = 'ServicePrincipal'
        }
    } | ConvertTo-Json -Depth 10

    $roleResp = Invoke-AzRestMethod -Path $roleAssignPath -Method PUT -Payload $roleAssignBody -ErrorAction SilentlyContinue
    if ($roleResp.StatusCode -ge 200 -and $roleResp.StatusCode -lt 300) {
        Write-Host "  • [MG: $MG_ID] $($role.Name) — granted." -ForegroundColor Green
    } elseif ($roleResp.StatusCode -eq 409) {
        Write-Host "  • [MG: $MG_ID] $($role.Name) — already assigned." -ForegroundColor Green
    } else {
        $errContent = $roleResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        $errMsg = if ($errContent -and $errContent.error) { $errContent.error.message } else { "HTTP $($roleResp.StatusCode)" }
        $failure = "[MG: $MG_ID] $($role.Name) — $errMsg"
        $roleAssignmentFailures += $failure
        Write-Warning "  • $failure"
    }
}

if ($roleAssignmentFailures.Count -gt 0) {
    Write-Error "One or more role assignments failed. Resolve RBAC assignment errors before continuing:`n - $($roleAssignmentFailures -join "`n - ")"
}

# Verify assignments for this principal at MG scope using role names (more robust in Gov)
$principalAssignments = @(Get-AzRoleAssignment -ObjectId $principalId -Scope $mgScope -ErrorAction SilentlyContinue)
$assignedRoleNames = @($principalAssignments | Select-Object -ExpandProperty RoleDefinitionName)

$requiredRoleNames = @($rolesToAssign | Select-Object -ExpandProperty Name)
$missingRoles = @($requiredRoleNames | Where-Object { $assignedRoleNames -notcontains $_ })

if ($missingRoles.Count -gt 0) {
    Write-Warning "Role verification mismatch for principal '$principalId' at MG scope. Missing: $($missingRoles -join ', ')."
    Write-Warning "Assigned roles detected for this principal: $($assignedRoleNames -join ', ')."
    Write-Warning "Deployment will continue; runbook preflight permission check will confirm effective rights at runtime."
} else {
    Write-Host "  Role assignment verification passed for managed identity at MG scope." -ForegroundColor Green
}

# ── Step 4: Import Az modules ──────────────────────────
Write-Host "`n[4/6] Importing required PowerShell modules..." -ForegroundColor Yellow

# Determine the correct PSGallery URI for the current cloud
$galleryUri = "https://www.powershellgallery.com/api/v2"
$azEnv = (Get-AzContext).Environment.Name
if ($azEnv -match 'Gov') {
    # PowerShell Gallery is the same URL for Gov; module content is cloud-agnostic
    Write-Host "  (Azure Government detected — modules are cloud-agnostic)" -ForegroundColor DarkGray
}

$modulesToImport = @(
    @{ Name = 'Az.Accounts';       Version = '3.0.0' },
    @{ Name = 'Az.PolicyInsights';  Version = '1.6.0' },
    @{ Name = 'Az.Resources';       Version = '7.0.0' }
)

foreach ($mod in $modulesToImport) {
    $existingMod = Get-AzAutomationModule -ResourceGroupName $AUTOMATION_RG_NAME -AutomationAccountName $AUTOMATION_ACCOUNT_NAME -Name $mod.Name -ErrorAction SilentlyContinue
    if ($existingMod -and $existingMod.ProvisioningState -eq 'Succeeded') {
        Write-Host "  • $($mod.Name) — already imported." -ForegroundColor Green
    } else {
        $contentUri = "$galleryUri/package/$($mod.Name)/$($mod.Version)"
        New-AzAutomationModule `
            -ResourceGroupName     $AUTOMATION_RG_NAME `
            -AutomationAccountName $AUTOMATION_ACCOUNT_NAME `
            -Name                  $mod.Name `
            -ContentLinkUri        $contentUri | Out-Null
        Write-Host "  • $($mod.Name) — import started (may take a few minutes)." -ForegroundColor Yellow
    }
}

# Wait for Az.Accounts to finish importing (other modules depend on it)
Write-Host "  Waiting for module imports to complete..." -ForegroundColor DarkGray
$maxWait = 20
for ($i = 1; $i -le $maxWait; $i++) {
    $acctMod = Get-AzAutomationModule -ResourceGroupName $AUTOMATION_RG_NAME -AutomationAccountName $AUTOMATION_ACCOUNT_NAME -Name 'Az.Accounts' -ErrorAction SilentlyContinue
    if ($acctMod -and $acctMod.ProvisioningState -eq 'Succeeded') { break }
    if ($acctMod -and $acctMod.ProvisioningState -eq 'Failed') {
        Write-Error "Az.Accounts module import failed. Check the Automation Account in the portal."
    }
    Start-Sleep -Seconds 15
}
Write-Host "  Module imports complete." -ForegroundColor Green

# ── Step 5: Import runbook + create variables ──────────
Write-Host "`n[5/6] Importing runbook and setting variables..." -ForegroundColor Yellow

$runbookName = 'AutoRemediation-TagEnforcement'
$runbookPath = Join-Path $PSScriptRoot 'AutoRemediation_Runbook.ps1'
$runbookVersion = Get-Date -Format 'yyyy-MM-dd.HHmmss'
$runbookHash = (Get-FileHash -Path $runbookPath -Algorithm SHA256).Hash

if (-not (Test-Path $runbookPath)) {
    Write-Error "Runbook script not found: $runbookPath"
}

# Import (or update) the runbook
Import-AzAutomationRunbook `
    -ResourceGroupName     $AUTOMATION_RG_NAME `
    -AutomationAccountName $AUTOMATION_ACCOUNT_NAME `
    -Name                  $runbookName `
    -Path                  $runbookPath `
    -Type                  PowerShell `
    -Published `
    -Force | Out-Null

Write-Host "  • Runbook '$runbookName' imported and published." -ForegroundColor Green
Write-Host "  • Runbook source version: $runbookVersion" -ForegroundColor Green
Write-Host "  • Runbook source hash   : $runbookHash" -ForegroundColor Green

# Create/update Automation variables used by the runbook
$automationVars = @(
    @{ Name = 'ManagementGroupId'; Value = $MG_ID },
    @{ Name = 'InitiativeName';    Value = $INITIATIVE_NAME },
    @{ Name = 'AssignmentName';    Value = $ASSIGNMENT_NAME },
    @{ Name = 'RunbookSourceVersion'; Value = $runbookVersion },
    @{ Name = 'RunbookSourceHash';    Value = $runbookHash }
)

foreach ($var in $automationVars) {
    $existing = Get-AzAutomationVariable -ResourceGroupName $AUTOMATION_RG_NAME -AutomationAccountName $AUTOMATION_ACCOUNT_NAME -Name $var.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Set-AzAutomationVariable `
            -ResourceGroupName     $AUTOMATION_RG_NAME `
            -AutomationAccountName $AUTOMATION_ACCOUNT_NAME `
            -Name                  $var.Name `
            -Value                 $var.Value `
            -Encrypted             $false | Out-Null
    } else {
        New-AzAutomationVariable `
            -ResourceGroupName     $AUTOMATION_RG_NAME `
            -AutomationAccountName $AUTOMATION_ACCOUNT_NAME `
            -Name                  $var.Name `
            -Value                 $var.Value `
            -Encrypted             $false | Out-Null
    }
    Write-Host "  • Variable '$($var.Name)' = '$($var.Value)'" -ForegroundColor Green
}

# ── Step 6: Create schedule and link to runbook ─────────
Write-Host "`n[6/6] Creating recurring schedule..." -ForegroundColor Yellow

$scheduleName = 'TagRemediation-Recurring'
$startTime = (Get-Date).AddHours(1).ToUniversalTime()

# Remove existing schedule if present (to update interval)
$existingSched = Get-AzAutomationSchedule -ResourceGroupName $AUTOMATION_RG_NAME -AutomationAccountName $AUTOMATION_ACCOUNT_NAME -Name $scheduleName -ErrorAction SilentlyContinue
if ($existingSched) {
    Remove-AzAutomationSchedule `
        -ResourceGroupName     $AUTOMATION_RG_NAME `
        -AutomationAccountName $AUTOMATION_ACCOUNT_NAME `
        -Name                  $scheduleName `
        -Force | Out-Null
}

New-AzAutomationSchedule `
    -ResourceGroupName     $AUTOMATION_RG_NAME `
    -AutomationAccountName $AUTOMATION_ACCOUNT_NAME `
    -Name                  $scheduleName `
    -StartTime             $startTime `
    -HourInterval          $scheduleHours `
    -TimeZone              'UTC' | Out-Null

Write-Host "  • Schedule '$scheduleName' — every $scheduleHours hour(s) starting at $($startTime.ToString('u'))" -ForegroundColor Green

# Link schedule to runbook
Register-AzAutomationScheduledRunbook `
    -ResourceGroupName     $AUTOMATION_RG_NAME `
    -AutomationAccountName $AUTOMATION_ACCOUNT_NAME `
    -RunbookName           $runbookName `
    -ScheduleName          $scheduleName | Out-Null

Write-Host "  • Runbook linked to schedule." -ForegroundColor Green

Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Auto-remediation setup complete." -ForegroundColor Cyan
Write-Host " The runbook will run every $scheduleHours hour(s) and" -ForegroundColor Cyan
Write-Host " automatically remediate non-compliant tags." -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

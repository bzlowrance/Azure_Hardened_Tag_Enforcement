<#
.SYNOPSIS
    Deploys the tag enforcement policy definitions, initiative, and assignment
    to an Azure management group.

.DESCRIPTION
    1. Creates/updates the three policy definitions (Owner, CostCode, BusinessUnit).
    2. Creates/updates the initiative (policy set definition) that bundles them.
    3. Creates/updates the policy assignment at the management group scope.
    4. Triggers a remediation task for each policy within the initiative.

    Reads configuration from ../.env and parameters from the assignment
    parameters file specified in .env.

.NOTES
    Prerequisites:
      - Az PowerShell module (Install-Module Az)
      - Logged in via Connect-AzAccount
      - Sufficient permissions on the target management group
        (Resource Policy Contributor + Tag Contributor)
#>

[CmdletBinding()]
param(
    [switch]$SkipRemediation
)

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

$MG_ID              = $envVars['MANAGEMENT_GROUP_ID']
$INITIATIVE_NAME    = $envVars['INITIATIVE_NAME']
$ASSIGNMENT_NAME    = $envVars['ASSIGNMENT_NAME']
$ASSIGNMENT_DISPLAY = $envVars['ASSIGNMENT_DISPLAY_NAME']
$PARAMS_FILE        = $envVars['ASSIGNMENT_PARAMETERS_FILE']
$locationPref       = $envVars['ASSIGNMENT_LOCATION']
$POLICY_OWNER       = $envVars['POLICY_DEF_OWNER']
$POLICY_COSTCODE    = $envVars['POLICY_DEF_COSTCODE']
$POLICY_BU          = $envVars['POLICY_DEF_BUSINESSUNIT']

# ── Resolve Azure region ────────────────────────────────
function Resolve-AzureLocation {
    param([string]$Preferred)

    $available = @(Get-AzLocation | Select-Object -ExpandProperty Location)
    if ($available.Count -eq 0) {
        Write-Error "No Azure locations available for the current subscription."
    }

    if ($Preferred -and $Preferred -ne 'AUTO') {
        if ($available -contains $Preferred) { return $Preferred }
        Write-Warning "Configured location '$Preferred' is not available for this subscription."
        Write-Warning "Available: $($available -join ', ')"
        Write-Host "Auto-detecting a suitable region..." -ForegroundColor Yellow
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
        'canadacentral', 'australiaeast', 'japaneast',
        'swedencentral', 'germanywestcentral', 'francecentral'
    )
    foreach ($r in $preferred) {
        if ($available -contains $r) { return $r }
    }

    return $available[0]
}

$mgScope         = "/providers/Microsoft.Management/managementGroups/$MG_ID"
$policiesDir     = Join-Path $repoRoot 'policies'
$paramsFilePath  = Join-Path $repoRoot $PARAMS_FILE

# Ensure we are in the context of a subscription under the target MG so
# Get-AzLocation returns the correct cloud-specific regions (gov, sovereign, etc.)
$mgSubs = @(Get-AzManagementGroupSubscription -GroupId $MG_ID -ErrorAction SilentlyContinue)
if ($mgSubs.Count -gt 0) {
    $targetSubId = ($mgSubs[0].Id -split '/')[-1]
    Set-AzContext -SubscriptionId $targetSubId -Force | Out-Null
}

$LOCATION = Resolve-AzureLocation -Preferred $locationPref

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Tag Enforcement Deployment" -ForegroundColor Cyan
Write-Host " Management Group : $MG_ID" -ForegroundColor Cyan
Write-Host " Location         : $LOCATION" -ForegroundColor Cyan
Write-Host " Initiative       : $INITIATIVE_NAME" -ForegroundColor Cyan
Write-Host " Assignment       : $ASSIGNMENT_NAME" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

# ── Step 1: Create / update policy definitions ──────────
Write-Host "`n[1/4] Creating policy definitions..." -ForegroundColor Yellow

$policyDefs = @(
    @{ Name = $POLICY_OWNER;    File = "enforce-tag-owner.json" },
    @{ Name = $POLICY_COSTCODE; File = "enforce-tag-costcode.json" },
    @{ Name = $POLICY_BU;       File = "enforce-tag-businessunit.json" }
)

foreach ($def in $policyDefs) {
    $filePath = Join-Path $policiesDir $def.File
    $json     = Get-Content $filePath -Raw | ConvertFrom-Json

    $ruleJson   = $json.properties.policyRule   | ConvertTo-Json -Depth 20
    $paramJson  = $json.properties.parameters   | ConvertTo-Json -Depth 20

    Write-Host "  • $($def.Name) ... " -NoNewline
    New-AzPolicyDefinition `
        -Name            $def.Name `
        -DisplayName     $json.properties.displayName `
        -Description     $json.properties.description `
        -Mode            $json.properties.mode `
        -Policy          $ruleJson `
        -Parameter       $paramJson `
        -Metadata        '{"category":"Tags"}' `
        -ManagementGroupName $MG_ID | Out-Null

    Write-Host "OK" -ForegroundColor Green
}

# Wait for policy definitions to propagate before creating the initiative
Write-Host "  Verifying policy definitions are available..." -ForegroundColor DarkGray
$maxRetries = 12
$retryDelay = 10
$allFound = $false
for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    $allFound = $true
    foreach ($def in $policyDefs) {
        $defId = "$mgScope/providers/Microsoft.Authorization/policyDefinitions/$($def.Name)"
        $check = Get-AzPolicyDefinition -Id $defId -ErrorAction SilentlyContinue
        if (-not $check) {
            $allFound = $false
            break
        }
    }
    if ($allFound) { break }
    if ($attempt -lt $maxRetries) {
        Write-Host "  Waiting for propagation (attempt $attempt/$maxRetries)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $retryDelay
    }
}
if (-not $allFound) {
    Write-Error "Policy definitions did not propagate within $($maxRetries * $retryDelay) seconds. Re-run the script to retry."
}
Write-Host "  All policy definitions verified." -ForegroundColor Green

# ── Step 2: Create / update the initiative ──────────────
Write-Host "`n[2/4] Creating initiative..." -ForegroundColor Yellow

$initFile = Join-Path $policiesDir 'initiative.json'
$initJson = Get-Content $initFile -Raw

# Replace the placeholder with the actual management group ID
$initJson = $initJson -replace '<MG_ID>', $MG_ID
$initObj  = $initJson | ConvertFrom-Json

$initParamJson  = $initObj.properties.parameters        | ConvertTo-Json -Depth 20
$initDefsJson   = $initObj.properties.policyDefinitions | ConvertTo-Json -Depth 20

New-AzPolicySetDefinition `
    -Name                $INITIATIVE_NAME `
    -DisplayName         $initObj.properties.displayName `
    -Description         $initObj.properties.description `
    -PolicyDefinition    $initDefsJson `
    -Parameter           $initParamJson `
    -Metadata            '{"category":"Tags","version":"5.0.0"}' `
    -ManagementGroupName $MG_ID | Out-Null

Write-Host "  • $INITIATIVE_NAME ... OK" -ForegroundColor Green

# ── Step 3: Create / update the assignment ──────────────
Write-Host "`n[3/4] Creating assignment..." -ForegroundColor Yellow

if (-not (Test-Path $paramsFilePath)) {
    Write-Error "Assignment parameters file not found: $paramsFilePath"
}

$params = Get-Content $paramsFilePath -Raw | ConvertFrom-Json

# Build the parameter hashtable for the assignment
$assignmentParams = @{
    defaultOwner                 = $params.defaultOwner
    ownerOverrides               = $params.ownerOverrides
    ownerResourceOverrides       = $params.ownerResourceOverrides
    defaultCostCode              = $params.defaultCostCode
    costCodeOverrides            = $params.costCodeOverrides
    costCodeResourceOverrides    = $params.costCodeResourceOverrides
    defaultBusinessUnit          = $params.defaultBusinessUnit
    businessUnitOverrides        = $params.businessUnitOverrides
    businessUnitResourceOverrides = $params.businessUnitResourceOverrides
}

$policySetDefId = "$mgScope/providers/Microsoft.Authorization/policySetDefinitions/$INITIATIVE_NAME"

New-AzPolicyAssignment `
    -Name                  $ASSIGNMENT_NAME `
    -DisplayName           $ASSIGNMENT_DISPLAY `
    -Scope                 $mgScope `
    -PolicySetDefinition   (Get-AzPolicySetDefinition -Id $policySetDefId) `
    -PolicyParameterObject $assignmentParams `
    -Location              $LOCATION `
    -IdentityType          'SystemAssigned' | Out-Null

Write-Host "  • $ASSIGNMENT_NAME ... OK" -ForegroundColor Green

# Grant the managed identity Tag Contributor on the MG scope
Write-Host "  • Granting Tag Contributor role to managed identity..." -NoNewline
$assignment = Get-AzPolicyAssignment -Name $ASSIGNMENT_NAME -Scope $mgScope
$principalId = $assignment.Identity.PrincipalId
$tagContributorRoleId = "4a9ae827-6dc8-4573-8ac7-8239d42aa03f"

# Check if role assignment already exists before creating
$existingRole = Get-AzRoleAssignment -ObjectId $principalId -Scope $mgScope -RoleDefinitionId $tagContributorRoleId -ErrorAction SilentlyContinue
if (-not $existingRole) {
    New-AzRoleAssignment `
        -ObjectId          $principalId `
        -Scope             $mgScope `
        -RoleDefinitionId  $tagContributorRoleId | Out-Null
}
Write-Host " OK" -ForegroundColor Green

# ── Step 4: Trigger remediation ─────────────────────────
if ($SkipRemediation) {
    Write-Host "`n[4/4] Remediation skipped (-SkipRemediation)." -ForegroundColor DarkGray
} else {
    Write-Host "`n[4/4] Starting remediation tasks..." -ForegroundColor Yellow

    $refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag')
    foreach ($refId in $refIds) {
        $remName = "remediate-$refId-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Host "  • $remName ... " -NoNewline

        Start-AzPolicyRemediation `
            -Name                          $remName `
            -PolicyAssignmentId            "$mgScope/providers/Microsoft.Authorization/policyAssignments/$ASSIGNMENT_NAME" `
            -PolicyDefinitionReferenceId   $refId `
            -Scope                         $mgScope | Out-Null

        Write-Host "OK" -ForegroundColor Green
    }
}

Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Deployment complete." -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

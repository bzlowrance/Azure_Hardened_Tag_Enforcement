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

$MG_ID              = $envVars['MANAGEMENT_GROUP_ID']
$INITIATIVE_NAME    = $envVars['INITIATIVE_NAME']
$ASSIGNMENT_NAME    = $envVars['ASSIGNMENT_NAME']
$ASSIGNMENT_DISPLAY = $envVars['ASSIGNMENT_DISPLAY_NAME']
$PARAMS_FILE        = $envVars['ASSIGNMENT_PARAMETERS_FILE']
$locationPref       = $envVars['ASSIGNMENT_LOCATION']
$POLICY_OWNER       = $envVars['POLICY_DEF_OWNER']
$POLICY_COSTCODE    = $envVars['POLICY_DEF_COSTCODE']
$POLICY_BU          = $envVars['POLICY_DEF_BUSINESSUNIT']

if ($ASSIGNMENT_NAME.Length -gt 24) {
    Write-Error "ASSIGNMENT_NAME '$ASSIGNMENT_NAME' is $($ASSIGNMENT_NAME.Length) chars; Azure Policy requires 24 or fewer characters."
}

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

function Invoke-AzRestWithApiFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathTemplate,
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,
        [string]$Payload,
        [string[]]$ApiVersions
    )

    $lastError = $null
    foreach ($apiVersion in $ApiVersions) {
        $path = $PathTemplate -replace '\{apiVersion\}', $apiVersion
        try {
            if ($Payload) {
                return Invoke-AzRestMethod -Path $path -Method $Method -Payload $Payload -ErrorAction Stop
            }
            return Invoke-AzRestMethod -Path $path -Method $Method -ErrorAction Stop
        } catch {
            $lastError = $_
            $msg = $_.Exception.Message
            # In sovereign clouds, newer API versions may lag. Try the next one.
            if ($msg -match 'InvalidApiVersionParameter|NoRegisteredProviderFound|The api-version') {
                continue
            }
            throw
        }
    }

    throw $lastError
}

$mgScope         = "/providers/Microsoft.Management/managementGroups/$MG_ID"
$policiesDir     = Join-Path $repoRoot 'policies'
$paramsFilePath  = Join-Path $repoRoot $PARAMS_FILE
$policyApiVersions = @('2023-04-01', '2022-06-01', '2021-06-01')

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
    $rawJson  = Get-Content $filePath -Raw

    Write-Host "  • $($def.Name) ... " -NoNewline

    # Use the REST API to create/update the definition — this avoids serialization
    # issues with ConvertTo-Json and handles gov/sovereign clouds correctly.
    $defApiPathTemplate = "/providers/Microsoft.Management/managementGroups/$MG_ID/providers/Microsoft.Authorization/policyDefinitions/$($def.Name)?api-version={apiVersion}"
    $defObj = $rawJson | ConvertFrom-Json

    $body = @{
        properties = @{
            displayName = $defObj.properties.displayName
            description = $defObj.properties.description
            mode        = $defObj.properties.mode
            metadata    = @{ category = 'Tags' }
            parameters  = $defObj.properties.parameters
            policyRule  = $defObj.properties.policyRule
        }
    } | ConvertTo-Json -Depth 30

    $response = Invoke-AzRestWithApiFallback -PathTemplate $defApiPathTemplate -Method PUT -Payload $body -ApiVersions $policyApiVersions
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
        Write-Host "OK" -ForegroundColor Green
    } else {
        Write-Host "FAILED ($($response.StatusCode))" -ForegroundColor Red
        $errContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errContent -and $errContent.error) {
            Write-Error "Failed to create policy '$($def.Name)': $($errContent.error.message)"
        } else {
            Write-Error "Failed to create policy '$($def.Name)': HTTP $($response.StatusCode) - $($response.Content)"
        }
    }
}

# Wait for policy definitions to propagate before creating the initiative
Write-Host "  Verifying policy definitions are available..." -ForegroundColor DarkGray
Start-Sleep -Seconds 10  # initial propagation delay
$maxRetries = 12
$retryDelay = 10
$allFound = $false
for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    $allFound = $true
    foreach ($def in $policyDefs) {
        $checkPathTemplate = "/providers/Microsoft.Management/managementGroups/$MG_ID/providers/Microsoft.Authorization/policyDefinitions/$($def.Name)?api-version={apiVersion}"
        try {
            $checkResp = Invoke-AzRestWithApiFallback -PathTemplate $checkPathTemplate -Method GET -ApiVersions $policyApiVersions
        } catch {
            $checkResp = $null
        }
        if (-not $checkResp -or $checkResp.StatusCode -ne 200) {
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

$initApiPathTemplate = "/providers/Microsoft.Management/managementGroups/$MG_ID/providers/Microsoft.Authorization/policySetDefinitions/${INITIATIVE_NAME}?api-version={apiVersion}"
$initBody = @{
    properties = @{
        displayName       = $initObj.properties.displayName
        description       = $initObj.properties.description
        metadata          = @{ category = 'Tags'; version = '5.0.0' }
        parameters        = $initObj.properties.parameters
        policyDefinitions = $initObj.properties.policyDefinitions
    }
} | ConvertTo-Json -Depth 30

$initResp = Invoke-AzRestWithApiFallback -PathTemplate $initApiPathTemplate -Method PUT -Payload $initBody -ApiVersions $policyApiVersions
if ($initResp.StatusCode -ge 200 -and $initResp.StatusCode -lt 300) {
    Write-Host "  • $INITIATIVE_NAME ... OK" -ForegroundColor Green
} else {
    $errContent = $initResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($errContent -and $errContent.error) {
        Write-Error "Failed to create initiative: $($errContent.error.message)"
    } else {
        Write-Error "Failed to create initiative: HTTP $($initResp.StatusCode) - $($initResp.Content)"
    }
}

# ── Step 3: Create / update the assignment ──────────────
Write-Host "`n[3/4] Creating assignment..." -ForegroundColor Yellow

if (-not (Test-Path $paramsFilePath)) {
    Write-Error "Assignment parameters file not found: $paramsFilePath"
}

$params = Get-Content $paramsFilePath -Raw | ConvertFrom-Json

function Ensure-PolicyValidatorPlaceholders {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Value,
        [Parameter(Mandatory = $true)]
        [ValidateSet('ResourceGroup', 'Resource')]
        [string]$Kind
    )

    $ht = @{}
    if ($null -ne $Value) {
        $Value.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    }

    if ($Kind -eq 'ResourceGroup') {
        if (-not $ht.ContainsKey('disabled')) { $ht['disabled'] = '' }
    } else {
        if (-not $ht.ContainsKey('disabled/disabled')) { $ht['disabled/disabled'] = '' }
    }

    return $ht
}

# Build parameter values (wrap each value per the ARM assignment schema)
$assignmentParamValues = @{
    defaultOwner                  = @{ value = $params.defaultOwner }
    ownerOverrides                = @{ value = (Ensure-PolicyValidatorPlaceholders -Value $params.ownerOverrides -Kind ResourceGroup) }
    ownerResourceOverrides        = @{ value = (Ensure-PolicyValidatorPlaceholders -Value $params.ownerResourceOverrides -Kind Resource) }
    defaultCostCode               = @{ value = $params.defaultCostCode }
    costCodeOverrides             = @{ value = (Ensure-PolicyValidatorPlaceholders -Value $params.costCodeOverrides -Kind ResourceGroup) }
    costCodeResourceOverrides     = @{ value = (Ensure-PolicyValidatorPlaceholders -Value $params.costCodeResourceOverrides -Kind Resource) }
    defaultBusinessUnit           = @{ value = $params.defaultBusinessUnit }
    businessUnitOverrides         = @{ value = (Ensure-PolicyValidatorPlaceholders -Value $params.businessUnitOverrides -Kind ResourceGroup) }
    businessUnitResourceOverrides = @{ value = (Ensure-PolicyValidatorPlaceholders -Value $params.businessUnitResourceOverrides -Kind Resource) }
}

$policySetDefId = "$mgScope/providers/Microsoft.Authorization/policySetDefinitions/$INITIATIVE_NAME"

$assignApiPathTemplate = "${mgScope}/providers/Microsoft.Authorization/policyAssignments/${ASSIGNMENT_NAME}?api-version={apiVersion}"
$assignBody = @{
    location   = $LOCATION
    identity   = @{ type = 'SystemAssigned' }
    properties = @{
        displayName        = $ASSIGNMENT_DISPLAY
        policyDefinitionId = $policySetDefId
        parameters         = $assignmentParamValues
    }
} | ConvertTo-Json -Depth 30

$assignResp = Invoke-AzRestWithApiFallback -PathTemplate $assignApiPathTemplate -Method PUT -Payload $assignBody -ApiVersions $policyApiVersions
if ($assignResp.StatusCode -ge 200 -and $assignResp.StatusCode -lt 300) {
    Write-Host "  • $ASSIGNMENT_NAME ... OK" -ForegroundColor Green
} else {
    $errContent = $assignResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($errContent -and $errContent.error) {
        Write-Error "Failed to create assignment: $($errContent.error.message)"
    } else {
        Write-Error "Failed to create assignment: HTTP $($assignResp.StatusCode) - $($assignResp.Content)"
    }
}

# Grant the managed identity Tag Contributor on the MG scope
Write-Host "  • Granting Tag Contributor role to managed identity..." -NoNewline
$assignContent = $assignResp.Content | ConvertFrom-Json
$principalId = $assignContent.identity.principalId
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

# ── Step 4: Trigger policy evaluation scan ─────────────
Write-Host "`n[4/5] Triggering policy evaluation scan..." -ForegroundColor Yellow

$scanStarted = $false
# Prefer REST first for cross-version reliability in Gov/sovereign clouds.
try {
    $triggerPathTemplate = "/providers/Microsoft.Management/managementGroups/$MG_ID/providers/Microsoft.PolicyInsights/policyStates/latest/triggerEvaluation?api-version={apiVersion}"
    $triggerApiVersions = @('2019-10-01', '2018-07-01-preview')
    $triggerResp = Invoke-AzRestWithApiFallback -PathTemplate $triggerPathTemplate -Method POST -ApiVersions $triggerApiVersions
    if ($triggerResp.StatusCode -ge 200 -and $triggerResp.StatusCode -lt 300) {
        $scanStarted = $true
        Write-Host "  • Policy evaluation scan started via REST for management group '$MG_ID'." -ForegroundColor Green
    }
} catch {
    Write-Warning "  Could not start compliance scan via REST: $($_.Exception.Message)"
}

$scanCmd = Get-Command Start-AzPolicyComplianceScan -ErrorAction SilentlyContinue
if (-not $scanStarted -and $scanCmd) {
    try {
        $scanParamNames = @($scanCmd.Parameters.Keys)
        if ($scanParamNames -contains 'ManagementGroupName') {
            Start-AzPolicyComplianceScan -ManagementGroupName $MG_ID | Out-Null
            $scanStarted = $true
        } elseif ($scanParamNames -contains 'Scope') {
            Start-AzPolicyComplianceScan -Scope $mgScope | Out-Null
            $scanStarted = $true
        } elseif ($scanParamNames -contains 'ResourceId') {
            Start-AzPolicyComplianceScan -ResourceId $mgScope | Out-Null
            $scanStarted = $true
        }

        if ($scanStarted) {
            Write-Host "  • Policy evaluation scan started for management group '$MG_ID'." -ForegroundColor Green
        } else {
            Write-Warning "  Start-AzPolicyComplianceScan is installed but does not expose a management group compatible parameter set."
        }
    } catch {
        Write-Warning "  Could not start compliance scan via cmdlet: $($_.Exception.Message)"
    }
}

if (-not $scanStarted) {
    Write-Warning "  Policy evaluation scan could not be started automatically. Remediation tasks will still run."
}

# ── Step 5: Trigger remediation ─────────────────────────
Write-Host "`n[5/5] Starting remediation tasks..." -ForegroundColor Yellow

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

Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Deployment complete." -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

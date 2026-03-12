<#
.SYNOPSIS
    Azure Automation runbook that triggers policy remediation tasks for the
    tag enforcement initiative.

.DESCRIPTION
    This runbook runs on a recurring schedule inside an Azure Automation Account.
    It authenticates using the Automation Account's system-assigned managed identity,
    then creates remediation tasks for each policy definition in the tag enforcement
    initiative. Remediations are created at management group scope using a custom
    RBAC role with explicit Microsoft.PolicyInsights permissions.

    Configuration is read from Automation Account variables:
        - ManagementGroupId   : Target management group
        - InitiativeName      : Policy set definition name
        - AssignmentName      : Policy assignment name

.NOTES
    Designed for Azure Government and commercial clouds.
    Requires Az.Accounts and Az.PolicyInsights modules imported into the Automation Account.
#>

# Authenticate with the Automation Account's managed identity
try {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Write-Output "Authenticated with managed identity."
} catch {
    Write-Error "Failed to authenticate with managed identity: $($_.Exception.Message)"
    throw
}

# Read configuration from Automation Account variables
$rawMgId         = [string](Get-AutomationVariable -Name 'ManagementGroupId')
$mgId            = ($rawMgId -replace '\s', '').Trim()
$initiativeName  = ([string](Get-AutomationVariable -Name 'InitiativeName')).Trim()
$assignmentName  = ([string](Get-AutomationVariable -Name 'AssignmentName')).Trim()
$sourceVersion   = Get-AutomationVariable -Name 'RunbookSourceVersion' -ErrorAction SilentlyContinue
$sourceHash      = Get-AutomationVariable -Name 'RunbookSourceHash' -ErrorAction SilentlyContinue

if ([string]::IsNullOrWhiteSpace($mgId)) {
    Write-Error "ManagementGroupId automation variable is empty after whitespace normalization."
    throw
}

if ($mgId -ne $rawMgId.Trim()) {
    Write-Warning "ManagementGroupId contained whitespace and was normalized from '$rawMgId' to '$mgId'."
}

$mgScope = "/providers/Microsoft.Management/managementGroups/$mgId"
$assignmentId = "$mgScope/providers/Microsoft.Authorization/policyAssignments/$assignmentName"

$resolvedSourceVersion = if ([string]::IsNullOrWhiteSpace($sourceVersion)) { 'unset' } else { $sourceVersion }
$resolvedSourceHash = if ([string]::IsNullOrWhiteSpace($sourceHash)) { 'unset' } else { $sourceHash }

Write-Output "Management Group : '$mgId'"
Write-Output "Initiative       : $initiativeName"
Write-Output "Assignment       : $assignmentName"
Write-Output "Runbook Version  : $resolvedSourceVersion"
Write-Output "Runbook Hash     : $resolvedSourceHash"
Write-Output "Remediation Scope: [$mgScope]"

# Preflight diagnostics: print caller and effective permissions at MG scope
try {
    $ctx = Get-AzContext
    if ($ctx -and $ctx.Account) {
        Write-Output "Auth Account ID  : $($ctx.Account.Id)"
    }

    $permPath = "${mgScope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    $permResp = Invoke-AzRestMethod -Path $permPath -Method GET -ErrorAction Stop
    if ($permResp.StatusCode -eq 200) {
        $permissions = (($permResp.Content | ConvertFrom-Json).value | ForEach-Object { $_.actions })
        $hasWritePermission = $false
        foreach ($actionSet in $permissions) {
            if ($actionSet -contains '*') { $hasWritePermission = $true; break }
            if ($actionSet -contains 'Microsoft.PolicyInsights/*') { $hasWritePermission = $true; break }
            if ($actionSet -contains 'Microsoft.PolicyInsights/remediations/*') { $hasWritePermission = $true; break }
            if ($actionSet -contains 'Microsoft.PolicyInsights/remediations/write') { $hasWritePermission = $true; break }
        }

        if ($hasWritePermission) {
            Write-Output "Permission Check : Microsoft.PolicyInsights/remediations/write = ALLOWED"
        } else {
            Write-Warning "Permission Check : Microsoft.PolicyInsights/remediations/write = NOT FOUND"
        }
    }
} catch {
    Write-Warning "Permission preflight check failed: $($_.Exception.Message)"
}

# ── Create remediation tasks at management group scope ───
Write-Output "Starting remediation tasks at MG scope..."

$refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag', 'enforceRgOwnerTag', 'enforceRgCostCodeTag', 'enforceRgBusinessUnitTag')
$remApiVersions = @('2021-10-01', '2019-07-01')
$loggedFirstRemPath = $false

foreach ($refId in $refIds) {
    $remName = "auto-rem-$refId-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $remBody = @{
        properties = @{
            policyAssignmentId          = $assignmentId
            policyDefinitionReferenceId = $refId
        }
    } | ConvertTo-Json -Depth 10

    $created = $false
    foreach ($apiVer in $remApiVersions) {
        try {
            $remPath = "${mgScope}/providers/Microsoft.PolicyInsights/remediations/${remName}?api-version=${apiVer}"
            $remPath = ($remPath -replace '\s', '')
            if (-not $loggedFirstRemPath) {
                Write-Output "First Remediation Path: [$remPath]"
                $loggedFirstRemPath = $true
            }
            $remResp = Invoke-AzRestMethod -Path $remPath -Method PUT -Payload $remBody -ErrorAction Stop
            if ($remResp.StatusCode -ge 200 -and $remResp.StatusCode -lt 300) {
                Write-Output "  Started: $remName"
                $created = $true
                break
            } elseif ($remResp.StatusCode -eq 404) {
                # API version not supported, try next
                continue
            } else {
                $errContent = $remResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
                $errMsg = if ($errContent -and $errContent.error) { $errContent.error.message } else { "HTTP $($remResp.StatusCode)" }
                Write-Warning "  Failed '$remName': $errMsg"
                $created = $true  # Don't retry with another API version for auth/param errors
                break
            }
        } catch {
            continue
        }
    }
    if (-not $created) {
        Write-Warning "  Failed '$remName': No compatible API version found."
    }
}

Write-Output "Auto-remediation runbook complete."

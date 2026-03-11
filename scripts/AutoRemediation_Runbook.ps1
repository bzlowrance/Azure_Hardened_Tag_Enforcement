<#
.SYNOPSIS
    Azure Automation runbook that triggers policy remediation tasks for the
    tag enforcement initiative.

.DESCRIPTION
    This runbook runs on a recurring schedule inside an Azure Automation Account.
    It authenticates using the Automation Account's system-assigned managed identity,
    then creates remediation tasks for each policy definition in the tag enforcement
    initiative at management group scope.

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
$mgId            = Get-AutomationVariable -Name 'ManagementGroupId'
$initiativeName  = Get-AutomationVariable -Name 'InitiativeName'
$assignmentName  = Get-AutomationVariable -Name 'AssignmentName'

$mgScope = "/providers/Microsoft.Management/managementGroups/$mgId"
$assignmentId = "$mgScope/providers/Microsoft.Authorization/policyAssignments/$assignmentName"

Write-Output "Management Group : $mgId"
Write-Output "Initiative       : $initiativeName"
Write-Output "Assignment       : $assignmentName"

# ── Trigger policy evaluation scan per subscription ─────
Write-Output "Triggering policy evaluation scans..."

$scanSubs = @(Get-AzManagementGroupSubscription -GroupId $mgId -ErrorAction SilentlyContinue)
foreach ($sub in $scanSubs) {
    $subId   = ($sub.Id -split '/')[-1]
    $subName = if ($sub.DisplayName) { $sub.DisplayName } else { $subId }
    try {
        $triggerPath = "/subscriptions/$subId/providers/Microsoft.PolicyInsights/policyStates/latest/triggerEvaluation?api-version=2019-10-01"
        $resp = Invoke-AzRestMethod -Path $triggerPath -Method POST -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
            Write-Output "  Scan triggered: $subName ($subId)"
        } else {
            Write-Warning "  Scan returned HTTP $($resp.StatusCode) for $subName"
        }
    } catch {
        Write-Warning "  Could not trigger scan for $subName : $($_.Exception.Message)"
    }
}

# Allow time for evaluation to begin processing
Write-Output "Waiting 30 seconds for evaluation to begin..."
Start-Sleep -Seconds 30

# ── Create remediation tasks ──────────────────────────
Write-Output "Starting remediation tasks..."

$refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag', 'enforceRgOwnerTag', 'enforceRgCostCodeTag', 'enforceRgBusinessUnitTag')
foreach ($refId in $refIds) {
    $remName = "auto-remediate-$refId-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    try {
        # Use REST API — Start-AzPolicyRemediation can fail with 403 in Gov even when roles are assigned
        $remPath = "${mgScope}/providers/Microsoft.PolicyInsights/remediations/${remName}?api-version=2021-10-01"
        $remBody = @{
            properties = @{
                policyAssignmentId          = $assignmentId
                policyDefinitionReferenceId = $refId
            }
        } | ConvertTo-Json -Depth 10

        $remResp = Invoke-AzRestMethod -Path $remPath -Method PUT -Payload $remBody -ErrorAction Stop
        if ($remResp.StatusCode -ge 200 -and $remResp.StatusCode -lt 300) {
            Write-Output "  Started: $remName"
        } else {
            $errContent = $remResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errMsg = if ($errContent -and $errContent.error) { $errContent.error.message } else { "HTTP $($remResp.StatusCode)" }
            Write-Warning "  Failed to start remediation '$remName': $errMsg"
        }
    } catch {
        Write-Warning "  Failed to start remediation '$remName': $($_.Exception.Message)"
    }
}

Write-Output "Auto-remediation runbook complete."

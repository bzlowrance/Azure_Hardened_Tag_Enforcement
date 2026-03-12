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
$mgId            = Get-AutomationVariable -Name 'ManagementGroupId'
$initiativeName  = Get-AutomationVariable -Name 'InitiativeName'
$assignmentName  = Get-AutomationVariable -Name 'AssignmentName'

$mgScope = "/providers/Microsoft.Management/managementGroups/$mgId"
$assignmentId = "$mgScope/providers/Microsoft.Authorization/policyAssignments/$assignmentName"

Write-Output "Management Group : $mgId"
Write-Output "Initiative       : $initiativeName"
Write-Output "Assignment       : $assignmentName"

# ── Create remediation tasks at management group scope ───
Write-Output "Starting remediation tasks at MG scope..."

$refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag', 'enforceRgOwnerTag', 'enforceRgCostCodeTag', 'enforceRgBusinessUnitTag')
$remApiVersions = @('2021-10-01', '2019-07-01')

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

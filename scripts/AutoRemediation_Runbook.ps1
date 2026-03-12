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

# Avoid inherited context artifacts between sandbox jobs.
Disable-AzContextAutosave -Scope Process | Out-Null

# Explicitly import required modules to reduce sandbox module-loading ambiguity.
$requiredAzModules = @('Az.Accounts', 'Az.Resources', 'Az.PolicyInsights')
foreach ($moduleName in $requiredAzModules) {
    try {
        Import-Module -Name $moduleName -ErrorAction Stop
    } catch {
        Write-Error "Failed to import required module '$moduleName': $($_.Exception.Message)"
        throw
    }
}

$loadedModuleVersions = @(
    $requiredAzModules | ForEach-Object {
        $m = Get-Module -Name $_ | Sort-Object Version -Descending | Select-Object -First 1
        if ($m) { "{0}={1}" -f $m.Name, $m.Version }
    }
) -join '; '
Write-Output "Loaded Modules   : $loadedModuleVersions"

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
$fallbackSubIdsRaw = [string](Get-AutomationVariable -Name 'FallbackSubscriptionIds' -ErrorAction SilentlyContinue)
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
Write-Output "Fallback Subs Var: [$fallbackSubIdsRaw]"

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

# ── Create remediation tasks (MG scope first, then sub fallback) ───
Write-Output "Starting remediation tasks at MG scope..."

$refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag', 'enforceRgOwnerTag', 'enforceRgCostCodeTag', 'enforceRgBusinessUnitTag')
$remApiVersions = @('2021-10-01', '2019-07-01')
$loggedFirstRemPath = $false
$mgScopeUnauthorized = $false

function Invoke-RemediationCreate {
    param(
        [Parameter(Mandatory=$true)][string]$Scope,
        [Parameter(Mandatory=$true)][string]$RefId,
        [Parameter(Mandatory=$true)][string]$AssignmentId,
        [ref]$LoggedFirstPath
    )

    $remName = "auto-rem-$RefId-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $remBody = @{
        properties = @{
            policyAssignmentId          = $AssignmentId
            policyDefinitionReferenceId = $RefId
        }
    } | ConvertTo-Json -Depth 10

    $unauthorized = $false
    foreach ($apiVer in $remApiVersions) {
        try {
            $remPath = "${Scope}/providers/Microsoft.PolicyInsights/remediations/${remName}?api-version=${apiVer}"
            $remPath = ($remPath -replace '\s', '')
            if (-not $LoggedFirstPath.Value) {
                Write-Output "First Remediation Path: [$remPath]"
                $LoggedFirstPath.Value = $true
            }

            $remResp = Invoke-AzRestMethod -Path $remPath -Method PUT -Payload $remBody -ErrorAction Stop
            if ($remResp.StatusCode -ge 200 -and $remResp.StatusCode -lt 300) {
                Write-Output "  Started: $remName"
                return @{ Created = $true; Unauthorized = $false }
            }

            $errContent = $remResp.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errMsg = if ($errContent -and $errContent.error) { $errContent.error.message } else { "HTTP $($remResp.StatusCode)" }
            Write-Warning "  Failed '$remName': $errMsg"
            if ($errMsg -match 'not have authorization|AuthorizationFailed|Microsoft\.PolicyInsights/remediations/write') {
                $unauthorized = $true
            }
            return @{ Created = $false; Unauthorized = $unauthorized }
        } catch {
            $exMsg = $_.Exception.Message
            if ($exMsg -match 'not have authorization|AuthorizationFailed|Microsoft\.PolicyInsights/remediations/write') {
                $unauthorized = $true
            }
            continue
        }
    }

    Write-Warning "  Failed '$remName': No compatible API version found."
    return @{ Created = $false; Unauthorized = $unauthorized }
}

foreach ($refId in $refIds) {
    $result = Invoke-RemediationCreate -Scope $mgScope -RefId $refId -AssignmentId $assignmentId -LoggedFirstPath ([ref]$loggedFirstRemPath)
    if ($result.Unauthorized) {
        $mgScopeUnauthorized = $true
    }
}

if ($mgScopeUnauthorized) {
    Write-Warning "MG-scope remediation creation was unauthorized. Falling back to subscription-scope remediation tasks."

    $scanSubIds = @()
    if (-not [string]::IsNullOrWhiteSpace($fallbackSubIdsRaw)) {
        $scanSubIds = @($fallbackSubIdsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($scanSubIds.Count -gt 0) {
            Write-Output "Using fallback subscription IDs from automation variable. Count: $($scanSubIds.Count)"
        }
    }

    if ($scanSubIds.Count -eq 0) {
        $scanSubs = @(Get-AzManagementGroupSubscription -GroupId $mgId -ErrorAction SilentlyContinue)
        $scanSubIds = @($scanSubs | ForEach-Object { ($_.Id -split '/')[-1] } | Where-Object { $_ })
    }

    if ($scanSubIds.Count -eq 0) {
        try {
            $mgDescPath = "/providers/Microsoft.Management/managementGroups/${mgId}/descendants?api-version=2020-05-01"
            $mgDescResp = Invoke-AzRestMethod -Path $mgDescPath -Method GET -ErrorAction Stop
            if ($mgDescResp.StatusCode -eq 200) {
                $descendants = ($mgDescResp.Content | ConvertFrom-Json).value
                $scanSubIds = @($descendants | Where-Object { $_.type -eq '/subscriptions' } | ForEach-Object { ($_.id -split '/')[-1] } | Where-Object { $_ })
            }
        } catch {
            Write-Warning "Subscription discovery fallback failed: $($_.Exception.Message)"
        }
    }

    if ($scanSubIds.Count -eq 0) {
        $ctxSubId = $null
        try {
            $ctx = Get-AzContext
            if ($ctx -and $ctx.Subscription -and $ctx.Subscription.Id) {
                $ctxSubId = [string]$ctx.Subscription.Id
            }
        } catch {
            $ctxSubId = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($ctxSubId)) {
            $scanSubIds = @($ctxSubId)
            Write-Warning "Using current context subscription for fallback: $ctxSubId"
        }
    }

    if ($scanSubIds.Count -eq 0) {
        Write-Warning "No subscriptions found under management group '$mgId'. Subscription-scope fallback cannot continue. Set automation variable 'FallbackSubscriptionIds'."
    } else {
        $scanSubIds = @($scanSubIds | Select-Object -Unique)
        Write-Output "Fallback target subscriptions: $($scanSubIds.Count)"
        foreach ($subId in $scanSubIds) {
            $subScope = "/subscriptions/$subId"
            Write-Output "  Subscription scope: $subScope"

            $subReachable = $false
            try {
                Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
                $subInfoResp = Invoke-AzRestMethod -Path "/subscriptions/$subId?api-version=2020-01-01" -Method GET -ErrorAction Stop
                if ($subInfoResp.StatusCode -eq 200) {
                    $subReachable = $true
                    Write-Output "  Subscription access check passed: $subId"
                }
            } catch {
                Write-Warning "  Subscription access check failed for '$subId': $($_.Exception.Message)"
            }

            if (-not $subReachable) {
                Write-Warning "  Skipping remediation at subscription scope '$subId' because subscription is not reachable in current context."
                continue
            }

            foreach ($refId in $refIds) {
                $null = Invoke-RemediationCreate -Scope $subScope -RefId $refId -AssignmentId $assignmentId -LoggedFirstPath ([ref]$loggedFirstRemPath)
            }
        }
    }
}

Write-Output "Auto-remediation runbook complete."

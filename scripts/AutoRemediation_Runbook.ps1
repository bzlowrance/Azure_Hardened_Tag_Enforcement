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

# ── Diagnostics: print identity context details ─────────
$ctx = Get-AzContext
$envName   = if ($ctx -and $ctx.Environment)   { $ctx.Environment.Name }   else { 'unknown' }
$tenantId  = if ($ctx -and $ctx.Tenant)        { [string]$ctx.Tenant.Id } else { $null }
$ctxSubId  = if ($ctx -and $ctx.Subscription)  { [string]$ctx.Subscription.Id } else { $null }

Write-Output "Auth Account ID  : $($ctx.Account.Id)"
Write-Output "Environment      : $envName"
Write-Output "Tenant           : $(if ($tenantId) { $tenantId } else { '(none)' })"
Write-Output "Context Sub      : $(if ($ctxSubId) { $ctxSubId } else { '(none)' })"

# ── Ensure a subscription is active in the context ──────
# Start-AzPolicyRemediation (and most ARM cmdlets) require a subscription
# in the current context to route requests through the correct ARM regional
# endpoint — even when the operation targets management-group scope.
#
# IMPORTANT: With Automation Account managed identities, Set-AzContext cannot
# resolve subscriptions that were not cached during Connect-AzAccount.  The
# reliable pattern is to re-call Connect-AzAccount -Identity -Subscription $id
# which authenticates directly against the target subscription.

$effectiveSubId = $null

# 1. Use the subscription already in context (Automation Account's subscription)
if (-not [string]::IsNullOrWhiteSpace($ctxSubId)) {
    $effectiveSubId = $ctxSubId
    Write-Output "Using context subscription: $effectiveSubId"
}

# 2. Try fallback subscription IDs from automation variable
if ([string]::IsNullOrWhiteSpace($effectiveSubId) -and -not [string]::IsNullOrWhiteSpace($fallbackSubIdsRaw)) {
    $fallbackSubIds = @($fallbackSubIdsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($subId in $fallbackSubIds) {
        try {
            $connectParams = @{ Identity = $true; Subscription = $subId; ErrorAction = 'Stop' }
            if (-not [string]::IsNullOrWhiteSpace($envName) -and $envName -ne 'unknown') {
                $connectParams['Environment'] = $envName
            }
            Connect-AzAccount @connectParams | Out-Null
            $effectiveSubId = $subId
            Write-Output "Connected to fallback subscription: $effectiveSubId"
            break
        } catch {
            Write-Warning "Could not connect to subscription '$subId': $($_.Exception.Message)"
        }
    }
}

# 3. Discover subscriptions under the management group
if ([string]::IsNullOrWhiteSpace($effectiveSubId)) {
    try {
        $mgSubs = @(Get-AzManagementGroupSubscription -GroupId $mgId -ErrorAction Stop)
        foreach ($mgSub in $mgSubs) {
            $discoveredSubId = ($mgSub.Id -split '/')[-1]
            try {
                $connectParams = @{ Identity = $true; Subscription = $discoveredSubId; ErrorAction = 'Stop' }
                if (-not [string]::IsNullOrWhiteSpace($envName) -and $envName -ne 'unknown') {
                    $connectParams['Environment'] = $envName
                }
                Connect-AzAccount @connectParams | Out-Null
                $effectiveSubId = $discoveredSubId
                Write-Output "Connected to discovered subscription: $effectiveSubId"
                break
            } catch {
                Write-Warning "Could not connect to discovered subscription '$discoveredSubId': $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Warning "Could not list subscriptions under MG '$mgId': $($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($effectiveSubId)) {
    Write-Error "No subscription context available. The managed identity must have Reader access on at least one subscription under the management group. Set automation variable 'FallbackSubscriptionIds'."
    throw "No subscription context available."
}

Write-Output "Effective Sub    : $effectiveSubId"

# ── Create remediation tasks using Start-AzPolicyRemediation ────
# This uses the same PowerShell cmdlet that works successfully in
# Deploy_Tag_Policies.ps1. The cmdlet handles ARM endpoint routing,
# API version selection, and token acquisition correctly — including
# Azure Government managed identities.
Write-Output "Starting remediation tasks..."

$refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag', 'enforceRgOwnerTag', 'enforceRgCostCodeTag', 'enforceRgBusinessUnitTag')

$successCount = 0
$failCount    = 0

foreach ($refId in $refIds) {
    $remName = "auto-rem-$refId-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $created = $false

    # Attempt MG-scope remediation (matches Deploy_Tag_Policies.ps1 approach)
    try {
        Start-AzPolicyRemediation `
            -Name                        $remName `
            -PolicyAssignmentId          $assignmentId `
            -PolicyDefinitionReferenceId $refId `
            -Scope                       $mgScope `
            -ErrorAction Stop | Out-Null

        Write-Output "  Started: $remName (MG scope)"
        $created = $true
        $successCount++
    } catch {
        Write-Warning "  MG-scope failed for '$refId': $($_.Exception.Message)"
    }

    # Subscription-scope fallback
    if (-not $created) {
        $subScope = "/subscriptions/$effectiveSubId"
        try {
            Start-AzPolicyRemediation `
                -Name                        $remName `
                -PolicyAssignmentId          $assignmentId `
                -PolicyDefinitionReferenceId $refId `
                -Scope                       $subScope `
                -ErrorAction Stop | Out-Null

            Write-Output "  Started: $remName (subscription fallback: $effectiveSubId)"
            $created = $true
            $successCount++
        } catch {
            Write-Warning "  Subscription fallback also failed for '$refId': $($_.Exception.Message)"
            $failCount++
        }
    }
}

Write-Output "Remediation summary: $successCount succeeded, $failCount failed out of $($refIds.Count) policies."
Write-Output "Auto-remediation runbook complete."

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

# Read cloud environment early — it's needed before the main variable block.
$cloudEnv = [string](Get-AutomationVariable -Name 'CloudEnvironment' -ErrorAction SilentlyContinue)

# Authenticate with the Automation Account's managed identity.
# Explicitly specify the cloud environment to ensure the correct ARM endpoint
# is used. Without this, the sandbox may default to AzureCloud even in Gov.
$connectParams = @{ Identity = $true; ErrorAction = 'Stop' }

# CloudEnvironment is set by Deploy_Auto_Remediation.ps1; fall back to
# well-known Gov environment name if the variable is not yet populated.
if (-not [string]::IsNullOrWhiteSpace($cloudEnv)) {
    $connectParams['Environment'] = $cloudEnv
    Write-Output "Using cloud environment from variable: $cloudEnv"
} else {
    # Default to AzureUSGovernment — change if deploying to commercial cloud
    $connectParams['Environment'] = 'AzureUSGovernment'
    Write-Output "CloudEnvironment variable not set — defaulting to AzureUSGovernment"
}

try {
    Connect-AzAccount @connectParams | Out-Null
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

# ── Establish a subscription context ─────────────────────
# Start-AzPolicyRemediation requires a subscription in the Az context.
$effectiveSubId = $null

# 1. Check if Connect-AzAccount already set a subscription
if (-not [string]::IsNullOrWhiteSpace($ctxSubId)) {
    $effectiveSubId = $ctxSubId
    Write-Output "Using context subscription: $effectiveSubId"
}

# 2. Try fallback subscription IDs from the automation variable
if ([string]::IsNullOrWhiteSpace($effectiveSubId) -and -not [string]::IsNullOrWhiteSpace($fallbackSubIdsRaw)) {
    $fallbackSubIds = @($fallbackSubIdsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($subId in $fallbackSubIds) {
        try {
            $subConnectParams = @{ Identity = $true; Subscription = $subId; ErrorAction = 'Stop' }
            if ($connectParams.ContainsKey('Environment')) { $subConnectParams['Environment'] = $connectParams['Environment'] }
            Connect-AzAccount @subConnectParams | Out-Null
            $effectiveSubId = $subId
            Write-Output "Connected to fallback subscription: $effectiveSubId"
            break
        } catch {
            Write-Warning "Could not connect to fallback subscription '$subId': $($_.Exception.Message)"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($effectiveSubId)) {
    Write-Output "Effective Sub    : $effectiveSubId"
} else {
    Write-Warning "No subscription context available. Remediation cmdlets may fail."
}

# ── Create remediation tasks ────────────────────────────
# Strategy:
#   1. Start-AzPolicyRemediation cmdlet at MG scope
#   2. Start-AzPolicyRemediation at subscription scope (fallback)
Write-Output "Starting remediation tasks..."

$refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag', 'enforceRgOwnerTag', 'enforceRgCostCodeTag', 'enforceRgBusinessUnitTag')

$successCount = 0
$failCount    = 0

foreach ($refId in $refIds) {
    $remName = "auto-rem-$refId-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $created = $false

    # Attempt 1: PowerShell cmdlet at MG scope
    if (-not [string]::IsNullOrWhiteSpace($effectiveSubId)) {
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
            Write-Warning "  MG scope failed for '$refId': $($_.Exception.Message)"
        }
    }

    # Attempt 2: Cmdlet subscription-scope fallback
    if (-not $created -and -not [string]::IsNullOrWhiteSpace($effectiveSubId)) {
        $subScope = "/subscriptions/$effectiveSubId"
        try {
            Start-AzPolicyRemediation `
                -Name                        $remName `
                -PolicyAssignmentId          $assignmentId `
                -PolicyDefinitionReferenceId $refId `
                -Scope                       $subScope `
                -ErrorAction Stop | Out-Null

            Write-Output "  Started: $remName (sub fallback: $effectiveSubId)"
            $created = $true
            $successCount++
        } catch {
            Write-Warning "  Sub fallback failed for '$refId': $($_.Exception.Message)"
        }
    }

    if (-not $created) { $failCount++ }
}

Write-Output "Remediation summary: $successCount succeeded, $failCount failed out of $($refIds.Count) policies."

if ($failCount -gt 0) {
    Write-Output ""
    Write-Output "RBAC DIAGNOSTIC: $failCount remediation(s) failed."
    Write-Output "  Verify in Portal: MG '$mgId' → Access control → Role assignments"
    Write-Output "    that the Automation Account MSI has Reader/Resource Policy Contributor."
    Write-Output "  MG-scope RBAC can take up to 10 minutes to propagate to child subscriptions."
    Write-Output "  Re-run Deploy_Auto_Remediation.ps1 if assignments are missing."
}

Write-Output "Auto-remediation runbook complete."

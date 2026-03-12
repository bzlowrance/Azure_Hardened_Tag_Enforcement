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

# ── Remediate → Evaluate → Repeat loop ──────────────────
# Each policy modify effect fixes one tag per evaluation cycle. Resources
# missing multiple tags need multiple passes (remediate, re-evaluate, repeat).
$refIds = @('enforceOwnerTag', 'enforceCostCodeTag', 'enforceBusinessUnitTag', 'enforceRgOwnerTag', 'enforceRgCostCodeTag', 'enforceRgBusinessUnitTag')

$maxPasses       = 5
$scanWaitSeconds = 180   # max wait per evaluation scan
$remWaitSeconds  = 300   # max wait for remediation provisioning
$totalSuccess    = 0
$totalFail       = 0

for ($pass = 1; $pass -le $maxPasses; $pass++) {
    Write-Output ""
    Write-Output "════════════════════════════════════════════════"
    Write-Output " Remediation pass $pass of $maxPasses"
    Write-Output "════════════════════════════════════════════════"

    $passSuccess  = 0
    $passFail     = 0
    $passRemNames = @()   # track names so we can poll provisioning state

    foreach ($refId in $refIds) {
        $remName = "auto-rem-$refId-pass${pass}-$(Get-Date -Format 'yyyyMMddHHmmss')"
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
                $passSuccess++
                $passRemNames += @{ Name = $remName; Scope = $mgScope }
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
                $passSuccess++
                $passRemNames += @{ Name = $remName; Scope = $subScope }
            } catch {
                Write-Warning "  Sub fallback failed for '$refId': $($_.Exception.Message)"
            }
        }

        if (-not $created) { $passFail++ }
    }

    $totalSuccess += $passSuccess
    $totalFail    += $passFail
    Write-Output "Pass $pass summary: $passSuccess succeeded, $passFail failed."

    if ($passFail -gt 0) {
        Write-Output ""
        Write-Output "RBAC DIAGNOSTIC: $passFail remediation(s) failed in pass $pass."
        Write-Output "  Verify in Portal: MG '$mgId' -> Access control -> Role assignments"
        Write-Output "    that the Automation Account MSI has Reader/Resource Policy Contributor."
        Write-Output "  Re-run Deploy_Auto_Remediation.ps1 if assignments are missing."
    }

    # Skip evaluation trigger after the last pass — nothing left to re-check
    if ($pass -eq $maxPasses) {
        Write-Output "Final pass complete — skipping re-evaluation."
        break
    }

    # ── Wait for remediation tasks to reach Succeeded ───
    if ($passRemNames.Count -gt 0) {
        Write-Output "Waiting for $($passRemNames.Count) remediation task(s) to reach Succeeded (up to ${remWaitSeconds}s)..."
        $remElapsed = 0
        $allSucceeded = $false
        while ($remElapsed -lt $remWaitSeconds) {
            Start-Sleep -Seconds 30
            $remElapsed += 30

            $pending = @()
            foreach ($rem in $passRemNames) {
                try {
                    $r = Get-AzPolicyRemediation -Name $rem.Name -Scope $rem.Scope -ErrorAction Stop
                    if ($r.ProvisioningState -ne 'Succeeded') {
                        $pending += "$($rem.Name)=$($r.ProvisioningState)"
                    }
                } catch {
                    $pending += "$($rem.Name)=QueryError"
                }
            }

            if ($pending.Count -eq 0) {
                Write-Output "  All remediation tasks Succeeded after ${remElapsed}s."
                $allSucceeded = $true
                break
            } else {
                Write-Output "  ${remElapsed}s — still pending: $($pending -join ', ')"
            }
        }

        if (-not $allSucceeded) {
            Write-Warning "Timed out waiting for remediation tasks. Continuing to evaluation scan."
        }
    } else {
        Write-Output "No remediation tasks started — waiting 30s before evaluation scan..."
        Start-Sleep -Seconds 30
    }

    # ── Trigger a compliance evaluation scan ────────────
    Write-Output "Triggering policy compliance scan for subscription $effectiveSubId..."
    $scanTriggered = $false
    $triggerPath = "/subscriptions/$effectiveSubId/providers/Microsoft.PolicyInsights/policyStates/latest/triggerEvaluation?api-version=2019-10-01"
    try {
        $triggerResp = Invoke-AzRestMethod -Path $triggerPath -Method POST -ErrorAction Stop
        if ($triggerResp.StatusCode -ge 200 -and $triggerResp.StatusCode -lt 300) {
            Write-Output "  Evaluation scan triggered (HTTP $($triggerResp.StatusCode))."
            $scanTriggered = $true
        } else {
            Write-Warning "  Scan trigger returned HTTP $($triggerResp.StatusCode)."
        }
    } catch {
        Write-Warning "  REST scan trigger failed: $($_.Exception.Message)"
    }

    if (-not $scanTriggered) {
        try {
            Start-AzPolicyComplianceScan -ErrorAction Stop
            Write-Output "  Evaluation scan triggered (cmdlet)."
            $scanTriggered = $true
        } catch {
            Write-Warning "  Cmdlet scan trigger failed: $($_.Exception.Message)"
        }
    }

    # ── Wait for the scan to detect remaining non-compliance ──
    if ($scanTriggered) {
        Write-Output "Waiting for evaluation scan to complete (up to ${scanWaitSeconds}s)..."
        $elapsed = 0
        while ($elapsed -lt $scanWaitSeconds) {
            Start-Sleep -Seconds 30
            $elapsed += 30
            Write-Output "  ... ${elapsed}s elapsed"

            # Check if scan has produced updated results
            $summaryPath = "/subscriptions/$effectiveSubId/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=2019-10-01"
            try {
                $summaryResp = Invoke-AzRestMethod -Path $summaryPath -Method POST -ErrorAction Stop
                if ($summaryResp.StatusCode -ge 200 -and $summaryResp.StatusCode -lt 300) {
                    $summary = ($summaryResp.Content | ConvertFrom-Json).value
                    $nonCompliant = if ($summary) { $summary[0].results.nonCompliantResources } else { 0 }
                    Write-Output "  Non-compliant resources: $nonCompliant"
                    if ($nonCompliant -eq 0) {
                        Write-Output "  All resources compliant — no further passes needed."
                        $pass = $maxPasses  # exit outer loop
                        break
                    }
                }
            } catch {
                Write-Warning "  Summary query failed: $($_.Exception.Message)"
            }
        }
    } else {
        # No scan triggered — wait a fixed period for natural evaluation
        Write-Output "No scan triggered — waiting 90s before next pass..."
        Start-Sleep -Seconds 90
    }
}

Write-Output ""
Write-Output "Overall remediation summary: $totalSuccess succeeded, $totalFail failed across $pass pass(es)."
Write-Output "Auto-remediation runbook complete."

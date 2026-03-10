<#
.SYNOPSIS
    Tears down all test infrastructure, policy objects, subscription, and
    management group created for tag enforcement testing.

.DESCRIPTION
    Removes resources in reverse order of creation:
      1. Deletes the policy assignment from the management group.
      2. Deletes the initiative (policy set definition).
      3. Deletes the three policy definitions.
      4. Deletes all staging resource groups (and everything inside them).
      5. Removes the subscription from the management group and cancels it
         (only if it was created by the staging script — i.e. matches the
         STAGING_SUBSCRIPTION_NAME in .env).
      6. Deletes the management group.

    Each step is guarded — if the resource doesn't exist it is skipped
    gracefully. A confirmation prompt is shown before any destructive action.

.PARAMETER SkipPolicyCleanup
    Skip removal of the policy assignment, initiative, and definitions.

.PARAMETER SkipResourceGroups
    Skip removal of resource groups.

.PARAMETER SkipSubscription
    Skip subscription cancellation and management group deletion.

.PARAMETER Force
    Suppress the confirmation prompt.

.NOTES
    Prerequisites:
      - Az PowerShell module
      - Logged in via Connect-AzAccount
      - Sufficient permissions to delete the resources created during staging
#>

[CmdletBinding()]
param(
    [switch]$SkipPolicyCleanup,
    [switch]$SkipResourceGroups,
    [switch]$SkipSubscription,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Load .env ───────────────────────────────────────────
$repoRoot = Split-Path -Parent $PSScriptRoot
$envFile  = Join-Path $repoRoot '.env'

if (-not (Test-Path $envFile)) {
    Write-Error "Missing .env file at $envFile."
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
$POLICY_OWNER       = $envVars['POLICY_DEF_OWNER']
$POLICY_COSTCODE    = $envVars['POLICY_DEF_COSTCODE']
$POLICY_BU          = $envVars['POLICY_DEF_BUSINESSUNIT']
$subscriptionIdRaw  = $envVars['STAGING_SUBSCRIPTION_ID']
$subscriptionName   = $envVars['STAGING_SUBSCRIPTION_NAME']
$rgPrefix           = $envVars['STAGING_RG_PREFIX']
$resourceGroups     = $envVars['STAGING_RESOURCE_GROUPS'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# When STAGING_SUBSCRIPTION_ID=CREATE_NEW the staging script created a
# subscription named STAGING_SUBSCRIPTION_NAME. We look it up by name so
# the destroy script can remove resource groups inside it, cancel it, and
# clean up the management group that was also created during staging.
$createdByStaging = ($subscriptionIdRaw -eq 'CREATE_NEW')

if ($createdByStaging) {
    $sub = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $subscriptionName -and $_.State -eq 'Enabled' }
    if ($sub) {
        $subscriptionId = $sub.Id
    } else {
        Write-Warning "Subscription '$subscriptionName' not found or already cancelled."
        $subscriptionId = $null
    }
} else {
    $subscriptionId = $subscriptionIdRaw
}

$mgScope = "/providers/Microsoft.Management/managementGroups/$MG_ID"

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Red
Write-Host " DESTROY Test Infrastructure" -ForegroundColor Red
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Red
Write-Host ""
Write-Host " Management Group  : $MG_ID" -ForegroundColor White
Write-Host " Subscription      : $(if ($subscriptionId) { $subscriptionId } else { '(not found)' })" -ForegroundColor White
Write-Host " Created by staging: $createdByStaging" -ForegroundColor White
Write-Host " Policy assignment : $ASSIGNMENT_NAME" -ForegroundColor White
Write-Host " Initiative        : $INITIATIVE_NAME" -ForegroundColor White
Write-Host " Policy definitions: $POLICY_OWNER, $POLICY_COSTCODE, $POLICY_BU" -ForegroundColor White
Write-Host " Resource groups   : $($resourceGroups -join ', ')" -ForegroundColor White
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "This will permanently delete the above resources. Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }
}

# ── Step 1: Remove policy assignment ───────────────────
if (-not $SkipPolicyCleanup) {
    Write-Host "`n[1/6] Removing policy assignment '$ASSIGNMENT_NAME'..." -ForegroundColor Yellow

    $policyApiVersions = @('2023-04-01', '2022-06-01', '2021-06-01')

    try {
        # Use REST to check for the assignment (cmdlet Identity property unreliable in Az.Resources 9.x)
        $assignPath = "${mgScope}/providers/Microsoft.Authorization/policyAssignments/${ASSIGNMENT_NAME}"
        $assignGetResp = $null
        foreach ($apiVer in $policyApiVersions) {
            try {
                $assignGetResp = Invoke-AzRestMethod -Path "${assignPath}?api-version=${apiVer}" -Method GET -ErrorAction Stop
                if ($assignGetResp.StatusCode -eq 200) { break }
            } catch { continue }
        }

        if ($assignGetResp -and $assignGetResp.StatusCode -eq 200) {
            # Remove any active remediation tasks first
            $remediations = @(Get-AzPolicyRemediation -Scope $mgScope -ErrorAction SilentlyContinue |
                Where-Object { $_.PolicyAssignmentId -like "*$ASSIGNMENT_NAME*" })
            foreach ($rem in $remediations) {
                Write-Host "  • Stopping remediation: $($rem.Name) ... " -NoNewline
                Stop-AzPolicyRemediation -Name $rem.Name -Scope $mgScope -ErrorAction SilentlyContinue | Out-Null
                Remove-AzPolicyRemediation -Name $rem.Name -Scope $mgScope -ErrorAction SilentlyContinue | Out-Null
                Write-Host "removed" -ForegroundColor Green
            }

            # Remove role assignment for the managed identity (read from REST response)
            $assignObj = $assignGetResp.Content | ConvertFrom-Json
            $principalId = $null
            if ($assignObj.identity -and $assignObj.identity.principalId) {
                $principalId = $assignObj.identity.principalId
            }
            if ($principalId) {
                Write-Host "  • Removing role assignments for managed identity..." -NoNewline
                Get-AzRoleAssignment -ObjectId $principalId -Scope $mgScope -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-AzRoleAssignment -InputObject $_ -ErrorAction SilentlyContinue }
                Write-Host " done" -ForegroundColor Green
            }

            # Delete assignment via REST
            $deleted = $false
            foreach ($apiVer in $policyApiVersions) {
                try {
                    $delResp = Invoke-AzRestMethod -Path "${assignPath}?api-version=${apiVer}" -Method DELETE -ErrorAction Stop
                    if ($delResp.StatusCode -ge 200 -and $delResp.StatusCode -lt 300) {
                        $deleted = $true
                        break
                    }
                } catch { continue }
            }
            if ($deleted) {
                Write-Host "  • Assignment removed." -ForegroundColor Green
            } else {
                Write-Warning "  Could not delete assignment via REST."
            }

            # Wait for deletion to propagate before removing initiative
            Start-Sleep -Seconds 5
        } else {
            Write-Host "  • Assignment not found, skipping." -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "  Could not remove assignment: $($_.Exception.Message)"
    }

    # ── Step 2: Remove initiative ───────────────────────
    Write-Host "`n[2/6] Removing initiative '$INITIATIVE_NAME'..." -ForegroundColor Yellow

    try {
        $initPath = "${mgScope}/providers/Microsoft.Authorization/policySetDefinitions/${INITIATIVE_NAME}"
        $deleted = $false
        foreach ($apiVer in $policyApiVersions) {
            try {
                $resp = Invoke-AzRestMethod -Path "${initPath}?api-version=${apiVer}" -Method DELETE -ErrorAction Stop
                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                    $deleted = $true
                    break
                } elseif ($resp.StatusCode -eq 404) {
                    Write-Host "  • Initiative not found, skipping." -ForegroundColor DarkGray
                    $deleted = $true  # not an error
                    break
                }
            } catch { continue }
        }
        if ($deleted -and $resp.StatusCode -ne 404) {
            Write-Host "  • Initiative removed." -ForegroundColor Green
            Start-Sleep -Seconds 5
        } elseif (-not $deleted) {
            Write-Warning "  Could not remove initiative."
        }
    } catch {
        Write-Warning "  Could not remove initiative: $($_.Exception.Message)"
    }

    # ── Step 3: Remove policy definitions ───────────────
    Write-Host "`n[3/6] Removing policy definitions..." -ForegroundColor Yellow

    foreach ($defName in @($POLICY_OWNER, $POLICY_COSTCODE, $POLICY_BU)) {
        try {
            $defPath = "${mgScope}/providers/Microsoft.Authorization/policyDefinitions/${defName}"
            $deleted = $false
            foreach ($apiVer in $policyApiVersions) {
                try {
                    $resp = Invoke-AzRestMethod -Path "${defPath}?api-version=${apiVer}" -Method DELETE -ErrorAction Stop
                    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                        $deleted = $true
                        break
                    } elseif ($resp.StatusCode -eq 404) {
                        Write-Host "  • $defName not found, skipping." -ForegroundColor DarkGray
                        $deleted = $true
                        break
                    }
                } catch { continue }
            }
            if ($deleted -and $resp.StatusCode -ne 404) {
                Write-Host "  • $defName removed." -ForegroundColor Green
            } elseif (-not $deleted) {
                Write-Warning "  Could not remove $defName."
            }
        } catch {
            Write-Warning "  Could not remove $defName`: $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "`n[1-3/6] Policy cleanup skipped (-SkipPolicyCleanup)." -ForegroundColor DarkGray
}

# ── Step 4: Remove resource groups ─────────────────────
if (-not $SkipResourceGroups) {
    Write-Host "`n[4/6] Removing resource groups..." -ForegroundColor Yellow

    if (-not $subscriptionId) {
        Write-Warning "Subscription not resolved — skipping resource group removal."
    } else {
        Set-AzContext -SubscriptionId $subscriptionId -Force | Out-Null

        # Also collect any RGs created from resource-level override keys
        # (these keys now contain the full RG name including the prefix)
        $paramsFilePath = Join-Path $repoRoot $envVars['ASSIGNMENT_PARAMETERS_FILE']
        $extraRgNames = @()
        if (Test-Path $paramsFilePath) {
            $params = Get-Content $paramsFilePath -Raw | ConvertFrom-Json
            foreach ($prop in @('ownerResourceOverrides', 'costCodeResourceOverrides', 'businessUnitResourceOverrides')) {
                if ($params.PSObject.Properties[$prop]) {
                    $params.$prop.PSObject.Properties | ForEach-Object {
                        $rg = ($_.Name -split '/', 2)[0]
                        if ($rg -ne 'disabled' -and $rg -ne 'disabled/disabled' -and $extraRgNames -notcontains $rg) {
                            $extraRgNames += $rg
                        }
                    }
                }
            }
        }

        # Build full RG names from the .env list (prefix-name)
        $standardRgNames = @($resourceGroups | ForEach-Object { "${rgPrefix}-${_}" })

        # Merge all RG names (deduplicated)
        $allRgNames = ($standardRgNames + $extraRgNames) | Sort-Object -Unique

        $jobs = @()
        foreach ($rgName in $allRgNames) {
            $existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Host "  • $rgName ... " -NoNewline
                $jobs += Remove-AzResourceGroup -Name $rgName -Force -AsJob
                Write-Host "deleting (async)" -ForegroundColor Yellow
            } else {
                Write-Host "  • $rgName not found, skipping." -ForegroundColor DarkGray
            }
        }

        if ($jobs.Count -gt 0) {
            Write-Host "`n  Waiting for resource group deletions to complete..." -ForegroundColor Cyan
            $jobs | Wait-Job | Out-Null

            $failed = $jobs | Where-Object { $_.State -eq 'Failed' }
            if ($failed) {
                Write-Warning "Some resource group deletions failed:"
                $failed | ForEach-Object {
                    $reason = if ($_.ChildJobs.Count -gt 0 -and $_.ChildJobs[0].Error.Count -gt 0) {
                        $_.ChildJobs[0].Error[0].ToString()
                    } else { $_.JobStateInfo.Reason }
                    Write-Warning "  $($_.Name): $reason"
                }
            } else {
                Write-Host "  All resource groups deleted successfully." -ForegroundColor Green
            }

            $jobs | Remove-Job -Force
        }
    }
} else {
    Write-Host "`n[4/6] Resource group removal skipped (-SkipResourceGroups)." -ForegroundColor DarkGray
}

# ── Steps 5-6: Subscription cancellation & management group deletion ──
# These steps ONLY run when the staging script created the subscription
# (STAGING_SUBSCRIPTION_ID=CREATE_NEW in .env). If an existing subscription
# ID was provided, we leave both the subscription and management group
# intact — only the resource groups and policy objects are removed.

if (-not $SkipSubscription -and $createdByStaging) {
    # ── Step 5: Cancel the subscription ──────────────────
    Write-Host "`n[5/6] Cancelling subscription '$subscriptionName'..." -ForegroundColor Yellow

    if ($subscriptionId) {
        $confirmCancel = Read-Host "  Cancel subscription '$subscriptionName' ($subscriptionId)? (yes/no)"
        if ($confirmCancel -ne 'yes') {
            Write-Host "  Subscription cancellation aborted by user." -ForegroundColor Yellow
        } else {
            try {
                # Remove subscription from the management group first
                Write-Host "  • Removing subscription from management group '$MG_ID'..." -NoNewline
                Remove-AzManagementGroupSubscription -GroupId $MG_ID -SubscriptionId $subscriptionId -ErrorAction SilentlyContinue | Out-Null
                Write-Host " done" -ForegroundColor Green

                # Cancel the subscription
                Write-Host "  • Cancelling subscription $subscriptionId..." -NoNewline
                Update-AzSubscription -SubscriptionId $subscriptionId -Action 'Cancel' | Out-Null
                Write-Host " cancelled" -ForegroundColor Green

                # Remove the subscription alias if it exists
                Write-Host "  • Removing subscription alias '$subscriptionName'..." -NoNewline
                Remove-AzSubscriptionAlias -AliasName $subscriptionName -ErrorAction SilentlyContinue | Out-Null
                Write-Host " done" -ForegroundColor Green
            } catch {
                Write-Warning "  Could not cancel subscription: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "  • Subscription not found, skipping." -ForegroundColor DarkGray
    }

    # ── Step 6: Delete the management group ──────────────
    Write-Host "`n[6/6] Deleting management group '$MG_ID'..." -ForegroundColor Yellow

    try {
        $existingMg = Get-AzManagementGroup -GroupId $MG_ID -ErrorAction SilentlyContinue
        if ($existingMg) {
            $confirmDelete = Read-Host "  Delete management group '$MG_ID'? (yes/no)"
            if ($confirmDelete -ne 'yes') {
                Write-Host "  Deletion aborted by user." -ForegroundColor Yellow
            } else {
                Remove-AzManagementGroup -GroupName $MG_ID | Out-Null
                Write-Host "  • Management group '$MG_ID' deleted." -ForegroundColor Green
            }
        } else {
            Write-Host "  • Management group not found, skipping." -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "  Could not delete management group: $($_.Exception.Message)"
    }
} elseif ($SkipSubscription) {
    Write-Host "`n[5-6/6] Subscription/MG cleanup skipped (-SkipSubscription)." -ForegroundColor DarkGray
} else {
    # STAGING_SUBSCRIPTION_ID was an existing GUID — move it back to its
    # original parent management group and then delete the test MG.
    Write-Host "`n[5/6] Moving subscription back to original management group..." -ForegroundColor Yellow

    $stateFile = Join-Path $repoRoot '.staging-state.json'
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        $originalParent = $state.OriginalParentMG

        Write-Host "  Original parent MG: $originalParent" -ForegroundColor White
        Write-Host "  About to move subscription '$subscriptionId' back to '$originalParent'." -ForegroundColor White
        $confirmMove = Read-Host "  Proceed with move? (yes/no)"
        if ($confirmMove -ne 'yes') {
            Write-Host "  Move aborted by user." -ForegroundColor Yellow
        } else {
            try {
                Remove-AzManagementGroupSubscription -GroupId $MG_ID -SubscriptionId $subscriptionId -ErrorAction SilentlyContinue | Out-Null
                New-AzManagementGroupSubscription -GroupId $originalParent -SubscriptionId $subscriptionId | Out-Null
                Write-Host "  • Subscription moved back to '$originalParent'." -ForegroundColor Green

                # Clean up state file
                Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "  Could not move subscription back: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Warning "  State file not found at $stateFile — cannot determine original parent MG."
        Write-Warning "  Subscription '$subscriptionId' remains under '$MG_ID'."
    }

    # ── Step 6: Delete the management group ──────────────
    Write-Host "`n[6/6] Deleting management group '$MG_ID'..." -ForegroundColor Yellow

    try {
        $existingMg = Get-AzManagementGroup -GroupId $MG_ID -ErrorAction SilentlyContinue
        if ($existingMg) {
            $confirmDelete = Read-Host "  Delete management group '$MG_ID'? (yes/no)"
            if ($confirmDelete -ne 'yes') {
                Write-Host "  Deletion aborted by user." -ForegroundColor Yellow
            } else {
                Remove-AzManagementGroup -GroupName $MG_ID | Out-Null
                Write-Host "  • Management group '$MG_ID' deleted." -ForegroundColor Green
            }
        } else {
            Write-Host "  • Management group not found, skipping." -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "  Could not delete management group: $($_.Exception.Message)"
    }
}

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Destroy complete." -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

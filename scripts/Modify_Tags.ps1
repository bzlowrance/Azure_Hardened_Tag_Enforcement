<#
.SYNOPSIS
    Applies deliberately non-compliant tag values to all resources to simulate
    manual tag tampering and test that Azure Policy auto-corrects them.

.DESCRIPTION
    Sets Owner, CostCode, and BusinessUnit tags to known-bad values on every
    resource under the management group (or a specific subscription). This
    simulates a user manually overwriting tags with incorrect values.

    After running this script, wait for the Azure Policy remediation cycle
    (or trigger one manually) and then run Validate_Tag_Enforcement to confirm
    the policy corrected all tags back to the enforced values.

    Non-compliant values applied:
      Owner        → "UNAUTHORIZED-OWNER"
      CostCode     → "INVALID-CC-0000"
      BusinessUnit → "WRONG-DEPARTMENT"

.PARAMETER WhatIf
    Preview changes without applying them.

.PARAMETER SubscriptionId
    Limit to a single subscription. If omitted, iterates all subscriptions
    under the management group.

.NOTES
    Prerequisites:
      - Az PowerShell module
      - Logged in via Connect-AzAccount
      - Tag Contributor (or Contributor) on the target scope
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Non-compliant tag values ────────────────────────────
$badTags = @{
    Owner        = 'UNAUTHORIZED-OWNER'
    CostCode     = 'INVALID-CC-0000'
    BusinessUnit = 'WRONG-DEPARTMENT'
}

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

$MG_ID = $envVars['MANAGEMENT_GROUP_ID']

# ── Gather subscriptions ────────────────────────────────
if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId)
} else {
    Write-Host "Enumerating subscriptions under management group '$MG_ID'..." -ForegroundColor Cyan
    $mgDescendants = Get-AzManagementGroupSubscription -GroupId $MG_ID
    $subscriptions = @($mgDescendants | ForEach-Object {
        Get-AzSubscription -SubscriptionId ($_.Id -split '/')[-1]
    })
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Modify Tags — Apply non-compliant values" -ForegroundColor Cyan
Write-Host " Subscriptions to process: $($subscriptions.Count)" -ForegroundColor Cyan
Write-Host " Bad values:" -ForegroundColor Cyan
$badTags.GetEnumerator() | ForEach-Object {
    Write-Host "   $($_.Key) = $($_.Value)" -ForegroundColor Cyan
}
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

$totalModified = 0
$totalSkipped  = 0

foreach ($sub in $subscriptions) {
    Write-Host "`n── Subscription: $($sub.Name) ($($sub.Id)) ──" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub.Id -Force | Out-Null

    $resources = Get-AzResource

    foreach ($resource in $resources) {
        $rgName       = $resource.ResourceGroupName
        $resourceName = $resource.Name
        $currentTags  = $resource.Tags
        if ($null -eq $currentTags) { $currentTags = @{} }

        # Check if tags already have the bad values (skip if so)
        $alreadyBad = $true
        foreach ($tagName in $badTags.Keys) {
            if ($currentTags[$tagName] -ne $badTags[$tagName]) {
                $alreadyBad = $false
                break
            }
        }

        if (-not $alreadyBad) {
            $changeDesc = ($badTags.GetEnumerator() | ForEach-Object {
                "$($_.Key): '$($currentTags[$_.Key])' → '$($_.Value)'"
            }) -join ', '

            if ($PSCmdlet.ShouldProcess("$rgName/$resourceName", "Set non-compliant tags: $changeDesc")) {
                Update-AzTag -ResourceId $resource.ResourceId -Tag $badTags -Operation Merge | Out-Null
                Write-Host "  TAMPERED  $rgName/$resourceName — $changeDesc" -ForegroundColor Red
                $totalModified++
            }
        } else {
            Write-Host "  SKIPPED  $rgName/$resourceName — already non-compliant" -ForegroundColor DarkGray
            $totalSkipped++
        }
    }
}

Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Complete. Tampered: $totalModified  |  Already bad: $totalSkipped" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host " Next: wait for policy remediation (or trigger manually)," -ForegroundColor Yellow
Write-Host " then run Validate_Tag_Enforcement to confirm the" -ForegroundColor Yellow
Write-Host " policy corrected all tags." -ForegroundColor Yellow

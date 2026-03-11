<#
.SYNOPSIS
    Validates that all resources and resource groups under the management group
    have the correct Owner, CostCode, and BusinessUnit tag values.

.DESCRIPTION
    Scans every resource group and resource in every subscription under the
    management group and compares current tag values against the expected values
    from the assignment parameters file (using the same resolution logic as the
    policies).

    Outputs a summary report to the console and optionally exports a CSV
    of all non-compliant resources.

.PARAMETER SubscriptionId
    Limit to a single subscription. If omitted, iterates all subscriptions
    under the management group.

.PARAMETER ExportCsv
    Path to export non-compliant resources as CSV. If omitted, results are
    only displayed in the console.

.NOTES
    Prerequisites:
      - Az PowerShell module
      - Logged in via Connect-AzAccount
      - Reader access on the target scope
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ExportCsv
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

$MG_ID       = $envVars['MANAGEMENT_GROUP_ID']
$PARAMS_FILE = $envVars['ASSIGNMENT_PARAMETERS_FILE']

$paramsFilePath = Join-Path $repoRoot $PARAMS_FILE
if (-not (Test-Path $paramsFilePath)) {
    Write-Error "Assignment parameters file not found: $paramsFilePath"
}

$params = Get-Content $paramsFilePath -Raw | ConvertFrom-Json

# ── Build lookup tables ─────────────────────────────────
function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)] $InputObject)
    process {
        if ($null -eq $InputObject) { return @{} }
        $ht = @{}
        $InputObject.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return $ht
    }
}

$tagConfig = @(
    @{
        TagName            = 'Owner'
        Default            = $params.defaultOwner
        RgOverrides        = $params.ownerOverrides        | ConvertTo-Hashtable
        ResourceOverrides  = $params.ownerResourceOverrides | ConvertTo-Hashtable
    },
    @{
        TagName            = 'CostCode'
        Default            = $params.defaultCostCode
        RgOverrides        = $params.costCodeOverrides        | ConvertTo-Hashtable
        ResourceOverrides  = $params.costCodeResourceOverrides | ConvertTo-Hashtable
    },
    @{
        TagName            = 'BusinessUnit'
        Default            = $params.defaultBusinessUnit
        RgOverrides        = $params.businessUnitOverrides        | ConvertTo-Hashtable
        ResourceOverrides  = $params.businessUnitResourceOverrides | ConvertTo-Hashtable
    }
)

function Resolve-TagValue {
    param(
        [hashtable]$Config,
        [string]$ResourceGroupName,
        [string]$ResourceName
    )
    $resourceKey = "$ResourceGroupName/$ResourceName"

    if ($Config.ResourceOverrides.ContainsKey($resourceKey)) {
        return $Config.ResourceOverrides[$resourceKey]
    }
    if ($Config.RgOverrides.ContainsKey($ResourceGroupName)) {
        return $Config.RgOverrides[$ResourceGroupName]
    }
    return $Config.Default
}

function Resolve-RgTagValue {
    param(
        [hashtable]$Config,
        [string]$ResourceGroupName
    )
    if ($Config.RgOverrides.ContainsKey($ResourceGroupName)) {
        return $Config.RgOverrides[$ResourceGroupName]
    }
    return $Config.Default
}

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

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Validate Tag Enforcement" -ForegroundColor Cyan
Write-Host " Subscriptions to scan: $($subscriptions.Count)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

$violations    = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalResources = 0
$compliant      = 0
$totalRgs       = 0
$compliantRgs   = 0

foreach ($sub in $subscriptions) {
    Write-Host "`n── Subscription: $($sub.Name) ($($sub.Id)) ──" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub.Id -Force | Out-Null

    # ── Validate resource groups ────────────────────────
    $resourceGroups = @(Get-AzResourceGroup)
    Write-Host "  Scanning $($resourceGroups.Count) resource groups..." -ForegroundColor DarkGray

    foreach ($rg in $resourceGroups) {
        $totalRgs++
        $rgName      = $rg.ResourceGroupName
        $currentTags = $rg.Tags
        if ($null -eq $currentTags) { $currentTags = @{} }

        $rgCompliant = $true

        foreach ($cfg in $tagConfig) {
            $expected = Resolve-RgTagValue -Config $cfg -ResourceGroupName $rgName
            $current  = $currentTags[$cfg.TagName]

            $issue = $null
            if ($null -eq $current -or $current -eq '') {
                $issue = 'Missing'
            } elseif ($current -ne $expected) {
                $issue = 'Wrong value'
            }

            if ($issue) {
                $rgCompliant = $false
                $violations.Add([PSCustomObject]@{
                    Subscription      = $sub.Name
                    SubscriptionId    = $sub.Id
                    ResourceGroup     = $rgName
                    ResourceName      = '(resource group)'
                    ResourceType      = 'Microsoft.Resources/subscriptions/resourceGroups'
                    ResourceId        = $rg.ResourceId
                    Tag               = $cfg.TagName
                    Issue             = $issue
                    CurrentValue      = if ($current) { $current } else { '(none)' }
                    ExpectedValue     = $expected
                })
            }
        }

        if ($rgCompliant) {
            $compliantRgs++
        }
    }

    # ── Validate resources ──────────────────────────────
    $resources = Get-AzResource

    foreach ($resource in $resources) {
        $totalResources++
        $rgName       = $resource.ResourceGroupName
        $resourceName = $resource.Name
        $currentTags  = $resource.Tags
        if ($null -eq $currentTags) { $currentTags = @{} }

        $resourceCompliant = $true

        foreach ($cfg in $tagConfig) {
            $expected = Resolve-TagValue -Config $cfg -ResourceGroupName $rgName -ResourceName $resourceName
            $current  = $currentTags[$cfg.TagName]

            # Determine violation type
            $issue = $null
            if ($null -eq $current -or $current -eq '') {
                $issue = 'Missing'
            } elseif ($current -ne $expected) {
                $issue = 'Wrong value'
            }

            if ($issue) {
                $resourceCompliant = $false
                $violations.Add([PSCustomObject]@{
                    Subscription      = $sub.Name
                    SubscriptionId    = $sub.Id
                    ResourceGroup     = $rgName
                    ResourceName      = $resourceName
                    ResourceType      = $resource.ResourceType
                    ResourceId        = $resource.ResourceId
                    Tag               = $cfg.TagName
                    Issue             = $issue
                    CurrentValue      = if ($current) { $current } else { '(none)' }
                    ExpectedValue     = $expected
                })
            }
        }

        if ($resourceCompliant) {
            $compliant++
        }
    }
}

# ── Summary ─────────────────────────────────────────────
$nonCompliantResources = @($violations | Where-Object { $_.ResourceType -ne 'Microsoft.Resources/subscriptions/resourceGroups' } | Select-Object -Property ResourceId -Unique).Count
$nonCompliantRgs      = @($violations | Where-Object { $_.ResourceType -eq 'Microsoft.Resources/subscriptions/resourceGroups' } | Select-Object -Property ResourceId -Unique).Count

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Validation Results" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Resource groups scanned : $totalRgs"
Write-Host "  Compliant RGs           : $compliantRgs" -ForegroundColor Green
Write-Host "  Non-compliant RGs       : $nonCompliantRgs" -ForegroundColor $(if ($nonCompliantRgs -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Resources scanned       : $totalResources"
Write-Host "  Compliant resources     : $compliant" -ForegroundColor Green
Write-Host "  Non-compliant resources : $nonCompliantResources" -ForegroundColor $(if ($nonCompliantResources -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Total tag violations    : $($violations.Count)" -ForegroundColor $(if ($violations.Count -gt 0) { 'Red' } else { 'Green' })

if ($violations.Count -gt 0) {
    Write-Host "`n── Non-Compliant Resources ──" -ForegroundColor Red
    $violations | Format-Table -AutoSize -Property ResourceGroup, ResourceName, Tag, Issue, CurrentValue, ExpectedValue

    if ($ExportCsv) {
        $violations | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Violations exported to: $ExportCsv" -ForegroundColor Yellow
    }

    Write-Host "`nTo fix all violations, run:" -ForegroundColor Yellow
    Write-Host "  .\4_Modify_Tags.ps1" -ForegroundColor White
    Write-Host "  .\4_Modify_Tags.ps1 -WhatIf   # (preview first)" -ForegroundColor DarkGray
} else {
    Write-Host "`nAll resources are compliant. No action needed." -ForegroundColor Green
}

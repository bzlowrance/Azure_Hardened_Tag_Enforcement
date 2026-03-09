<#
.SYNOPSIS
    Creates all Azure infrastructure needed to test tag enforcement policies.

.DESCRIPTION
    Provisions the full test environment in order:
      1. Management group (if it doesn't exist).
      2. Subscription — creates a new "tag-validation-test" subscription
         (or uses an existing one if STAGING_SUBSCRIPTION_ID is set to a GUID).
      3. Places the subscription under the management group.
      4. Resource groups listed in .env (STAGING_RESOURCE_GROUPS).
      5. Lightweight Storage Accounts per resource group and for every
         resource-level override key in the assignment parameters file.

    Resources are created WITHOUT any enforced tags — tag application and
    correction are handled by the policy, Modify_Tags, and Validate scripts.

.NOTES
    Prerequisites:
      - Az PowerShell module (Az.Accounts, Az.Resources, Az.Storage, Az.Subscription)
      - Logged in via Connect-AzAccount
      - If STAGING_SUBSCRIPTION_ID=CREATE_NEW: billing account details in .env
        and permission to create subscriptions
      - Management Group Contributor on the tenant root (to create MG)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Ensure required Az modules are available ────────────
foreach ($mod in @('Az.Accounts', 'Az.Resources', 'Az.Storage', 'Az.Subscription')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing missing module '$mod'..." -ForegroundColor Yellow
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
    }
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

$MG_ID              = $envVars['MANAGEMENT_GROUP_ID']
$subscriptionId     = $envVars['STAGING_SUBSCRIPTION_ID']
$subscriptionName   = $envVars['STAGING_SUBSCRIPTION_NAME']
$billingAccount     = $envVars['STAGING_BILLING_ACCOUNT_NAME']
$billingProfile     = $envVars['STAGING_BILLING_PROFILE_NAME']
$invoiceSection     = $envVars['STAGING_INVOICE_SECTION_NAME']
$locationPref       = $envVars['STAGING_LOCATION']
$workloadPreference = $envVars['STAGING_WORKLOAD']   # optional override: Production or DevTest
$rgPrefix           = $envVars['STAGING_RG_PREFIX']
$resourceGroups     = $envVars['STAGING_RESOURCE_GROUPS'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$paramsFilePath     = Join-Path $repoRoot $envVars['ASSIGNMENT_PARAMETERS_FILE']

# ── Resolve Azure region ────────────────────────────────
# Honours .env value if set; otherwise auto-detects from the subscription's
# available regions (handles commercial, gov, and sovereign clouds).
function Resolve-AzureLocation {
    param([string]$Preferred)

    # Get only the locations available to the current subscription
    $available = @(Get-AzLocation | Select-Object -ExpandProperty Location)
    if ($available.Count -eq 0) {
        Write-Error "No Azure locations available for the current subscription. Verify your login and subscription context."
    }

    # If a preference is set, validate it against available locations
    if ($Preferred -and $Preferred -ne 'AUTO') {
        if ($available -contains $Preferred) { return $Preferred }
        Write-Warning "Configured location '$Preferred' is not available for this subscription."
        Write-Warning "Available: $($available -join ', ')"
        Write-Host "Auto-detecting a suitable region..." -ForegroundColor Yellow
    }

    # 1) Check existing resource groups for the most-used region
    $existingRgs = @(Get-AzResourceGroup -ErrorAction SilentlyContinue)
    if ($existingRgs.Count -gt 0) {
        $topRegion = $existingRgs |
            Group-Object Location |
            Sort-Object Count -Descending |
            Select-Object -First 1
        if ($topRegion -and ($available -contains $topRegion.Name)) {
            return $topRegion.Name
        }
    }

    # 2) Prefer well-known general-purpose regions if available
    $preferred = @(
        'eastus2', 'eastus', 'westus2', 'centralus',               # Commercial US
        'usgovvirginia', 'usgovarizona', 'usgovtexas',             # US Government
        'westeurope', 'northeurope', 'uksouth',                     # Europe
        'canadacentral', 'australiaeast', 'japaneast',              # Other
        'swedencentral', 'germanywestcentral', 'francecentral'
    )
    foreach ($r in $preferred) {
        if ($available -contains $r) { return $r }
    }

    # 3) Fallback: first available region
    return $available[0]
}

$location = Resolve-AzureLocation -Preferred $locationPref

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Stage Test Infrastructure" -ForegroundColor Cyan
Write-Host " Management Group : $MG_ID" -ForegroundColor Cyan
Write-Host " Location         : $location" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

# ── Step 1: Create management group ─────────────────────
Write-Host "`n[1/5] Creating management group '$MG_ID'..." -ForegroundColor Yellow

$existingMg = Get-AzManagementGroup -GroupId $MG_ID -ErrorAction SilentlyContinue
if ($existingMg) {
    Write-Host "  • Management group '$MG_ID' already exists." -ForegroundColor DarkGray
} else {
    New-AzManagementGroup -GroupName $MG_ID -DisplayName "Tag Enforcement Test" | Out-Null
    Write-Host "  • Management group '$MG_ID' created." -ForegroundColor Green
}

# ── Step 2: Create or resolve subscription ──────────────
Write-Host "`n[2/5] Provisioning subscription..." -ForegroundColor Yellow

if ($subscriptionId -eq 'CREATE_NEW') {
    if (-not $subscriptionName) {
        Write-Error "STAGING_SUBSCRIPTION_NAME must be set in .env when STAGING_SUBSCRIPTION_ID=CREATE_NEW."
    }

    # Check if a subscription with this name already exists
    $existingSub = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $subscriptionName -and $_.State -eq 'Enabled' }

    if ($existingSub) {
        $subscriptionId = $existingSub.Id
        Write-Host "  • Subscription '$subscriptionName' already exists ($subscriptionId)." -ForegroundColor DarkGray
    } else {
        # Auto-detect billing details from the current login when not specified
        if (-not $billingAccount -or -not $billingProfile -or -not $invoiceSection) {
            Write-Host "  • Billing details not set in .env — auto-detecting from current account..." -ForegroundColor DarkGray

            $billingAccounts = @(Get-AzBillingAccount -ErrorAction Stop)
            if ($billingAccounts.Count -eq 0) {
                Write-Error "No billing accounts found for the current login. Set STAGING_BILLING_ACCOUNT_NAME, STAGING_BILLING_PROFILE_NAME, and STAGING_INVOICE_SECTION_NAME in .env manually."
            }
            $ba = $billingAccounts | Select-Object -First 1
            $billingAccount = $ba.Name
            Write-Host "    Billing account : $billingAccount" -ForegroundColor DarkGray

            $profiles = @(Get-AzBillingProfile -BillingAccountName $billingAccount -ErrorAction Stop)
            if ($profiles.Count -eq 0) {
                Write-Error "No billing profiles found under account '$billingAccount'. Set billing fields in .env manually."
            }
            $bp = $profiles | Select-Object -First 1
            $billingProfile = $bp.Name
            Write-Host "    Billing profile : $billingProfile" -ForegroundColor DarkGray

            $sections = @(Get-AzInvoiceSection -BillingAccountName $billingAccount -BillingProfileName $billingProfile -ErrorAction Stop)
            if ($sections.Count -eq 0) {
                Write-Error "No invoice sections found under profile '$billingProfile'. Set billing fields in .env manually."
            }
            $is = $sections | Select-Object -First 1
            $invoiceSection = $is.Name
            Write-Host "    Invoice section : $invoiceSection" -ForegroundColor DarkGray
        }

        $billingScope = "/providers/Microsoft.Billing/billingAccounts/$billingAccount/billingProfiles/$billingProfile/invoiceSections/$invoiceSection"

        # Query the billing profile to discover which Azure plans (workloads) are enabled
        $bpApiPath  = "/providers/Microsoft.Billing/billingAccounts/$billingAccount/billingProfiles/${billingProfile}?api-version=2024-04-01"
        $bpResponse = Invoke-AzRestMethod -Path $bpApiPath -Method GET -ErrorAction Stop
        $bpContent  = $bpResponse.Content | ConvertFrom-Json

        $availableWorkloads = @()
        if ($bpContent.properties.enabledAzurePlans) {
            foreach ($plan in @($bpContent.properties.enabledAzurePlans)) {
                # skuId 0001 = Microsoft Azure Plan (Production)
                # skuId 0002 = Microsoft Azure Plan for DevTest
                if ($plan.skuId -eq '0001') { $availableWorkloads += 'Production' }
                if ($plan.skuId -eq '0002') { $availableWorkloads += 'DevTest' }
            }
        }

        if ($availableWorkloads.Count -eq 0) {
            Write-Error "No Azure subscription plans are enabled on billing profile '$billingProfile'. Enable a plan in the Azure portal under Cost Management + Billing."
        }

        # Select workload: honour .env preference if valid, otherwise auto-select
        if ($workloadPreference -and $availableWorkloads -contains $workloadPreference) {
            $workload = $workloadPreference
            Write-Host "  • Using requested workload: $workload" -ForegroundColor DarkGray
        } elseif ($availableWorkloads.Count -eq 1) {
            $workload = $availableWorkloads[0]
            Write-Host "  • Auto-selected workload: $workload (only available plan)" -ForegroundColor DarkGray
        } else {
            # Multiple plans available — prompt the user to choose
            Write-Host "  • Multiple Azure plans available:" -ForegroundColor White
            for ($i = 0; $i -lt $availableWorkloads.Count; $i++) {
                Write-Host "      [$($i + 1)] $($availableWorkloads[$i])" -ForegroundColor Cyan
            }
            $choice = $null
            while (-not $choice) {
                $input = Read-Host "    Select a plan (1-$($availableWorkloads.Count))"
                $index = $input -as [int]
                if ($index -ge 1 -and $index -le $availableWorkloads.Count) {
                    $choice = $availableWorkloads[$index - 1]
                } else {
                    Write-Host "    Invalid selection. Please enter a number between 1 and $($availableWorkloads.Count)." -ForegroundColor Red
                }
            }
            $workload = $choice
            Write-Host "  • Selected workload: $workload" -ForegroundColor DarkGray
        }

        Write-Host "  • Creating subscription '$subscriptionName' ($workload)..." -NoNewline
        try {
            $newSub = New-AzSubscriptionAlias `
                -AliasName   $subscriptionName `
                -DisplayName $subscriptionName `
                -BillingScope $billingScope `
                -Workload    $workload
        } catch {
            # The cmdlet may throw but still create the subscription — continue to lookup
            Write-Host "" # newline after -NoNewline
            Write-Warning "New-AzSubscriptionAlias reported an error: $($_.Exception.Message)"
            Write-Host "  • Checking if the subscription was created anyway..." -ForegroundColor DarkGray
            $newSub = $null
        }

        # Try to extract the subscription ID from the response object
        $subscriptionId = $null
        if ($newSub) {
            # Different Az.Subscription module versions return different shapes
            if ($newSub.PSObject.Properties['Properties'] -and $newSub.Properties.PSObject.Properties['SubscriptionId']) {
                $subscriptionId = $newSub.Properties.SubscriptionId
            } elseif ($newSub.PSObject.Properties['SubscriptionId']) {
                $subscriptionId = $newSub.SubscriptionId
            }
        }

        # Fallback: look up the subscription by name
        if (-not $subscriptionId) {
            Start-Sleep -Seconds 10  # brief wait for propagation
            $lookedUp = Get-AzSubscription -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $subscriptionName -and $_.State -eq 'Enabled' } |
                Select-Object -First 1
            if ($lookedUp) {
                $subscriptionId = $lookedUp.Id
            }
        }

        if (-not $subscriptionId) {
            Write-Error "Could not determine the subscription ID after creation. Check the Azure portal for subscription '$subscriptionName'."
        }
        Write-Host " created ($subscriptionId)" -ForegroundColor Green
    }
} else {
    if (-not $subscriptionId -or $subscriptionId -eq '00000000-0000-0000-0000-000000000000') {
        Write-Error "Set STAGING_SUBSCRIPTION_ID in .env to a valid subscription ID or CREATE_NEW."
    }
    Write-Host "  • Using existing subscription: $subscriptionId" -ForegroundColor DarkGray
}

# ── Step 3: Move subscription under management group ────
Write-Host "`n[3/5] Placing subscription under management group '$MG_ID'..." -ForegroundColor Yellow

$mgSubs = Get-AzManagementGroupSubscription -GroupId $MG_ID -ErrorAction SilentlyContinue
$alreadyUnderMg = $mgSubs | Where-Object { $_.Id -like "*$subscriptionId*" }

if ($alreadyUnderMg) {
    Write-Host "  • Subscription is already under '$MG_ID'." -ForegroundColor DarkGray
} else {
    # Record the subscription's current parent management group so the
    # destroy script can move it back when STAGING_SUBSCRIPTION_ID is a GUID.
    $stateFile = Join-Path $repoRoot '.staging-state.json'
    $originalParent = $null

    # Find the current parent by searching all management groups
    $allMgs = Get-AzManagementGroup -ErrorAction SilentlyContinue
    foreach ($mg in $allMgs) {
        $mgSubList = @(Get-AzManagementGroupSubscription -GroupId $mg.Name -ErrorAction SilentlyContinue)
        $childSub = $mgSubList | Where-Object { $_.Id -like "*$subscriptionId*" }
        if ($childSub) {
            $originalParent = $mg.Name
            break
        }
    }

    # If not found under any MG, it's under the tenant root group
    if (-not $originalParent) {
        $tenantId = (Get-AzContext).Tenant.Id
        $originalParent = $tenantId
    }

    # Save state to disk
    @{ OriginalParentMG = $originalParent; SubscriptionId = $subscriptionId } |
        ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
    Write-Host "  • Recorded original parent MG: $originalParent" -ForegroundColor DarkGray

    Write-Host ""
    Write-Host "  About to move subscription '$subscriptionId' from '$originalParent' to '$MG_ID'." -ForegroundColor White
    $confirmMove = Read-Host "  Proceed with move? (yes/no)"
    if ($confirmMove -ne 'yes') {
        Write-Host "  Move aborted by user." -ForegroundColor Yellow
        return
    }

    New-AzManagementGroupSubscription -GroupId $MG_ID -SubscriptionId $subscriptionId | Out-Null
    Write-Host "  • Subscription moved under '$MG_ID'." -ForegroundColor Green
}

# ── Set subscription context ───────────────────────────
Set-AzContext -SubscriptionId $subscriptionId -Force | Out-Null

# ── Parse assignment parameters for resource-level overrides ──
$params = Get-Content $paramsFilePath -Raw | ConvertFrom-Json

$resourceOverrideKeys = @()
foreach ($prop in @('ownerResourceOverrides', 'costCodeResourceOverrides', 'businessUnitResourceOverrides')) {
    if ($params.PSObject.Properties[$prop]) {
        $params.$prop.PSObject.Properties | ForEach-Object {
            if ($resourceOverrideKeys -notcontains $_.Name) {
                $resourceOverrideKeys += $_.Name
            }
        }
    }
}

# ── Helper: generate a storage-safe name ────────────────
function New-StorageName {
    param([string]$BaseName)
    $safeName = ($BaseName -replace '[^a-zA-Z0-9]', '').ToLower()
    $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    $name = "$safeName$suffix"
    if ($name.Length -gt 24) { $name = $name.Substring(0, 24) }
    if ($name.Length -lt 3) { $name = "stg$name$suffix" }
    return $name
}

# ── Step 4: Create resource groups ──────────────────────
Write-Host "`n[4/5] Creating resource groups..." -ForegroundColor Yellow

foreach ($rg in $resourceGroups) {
    $rgName = "$rgPrefix$rg"
    Write-Host "  • $rgName ... " -NoNewline
    $existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "exists" -ForegroundColor DarkGray
    } else {
        New-AzResourceGroup -Name $rgName -Location $location -Force | Out-Null
        Write-Host "created" -ForegroundColor Green
    }
}

# ── Step 5: Create storage accounts ────────────────────
Write-Host "`n[5/5] Creating storage accounts..." -ForegroundColor Yellow

# 5a: Baseline storage account per RG
foreach ($rg in $resourceGroups) {
    $rgName = "$rgPrefix$rg"
    $storageName = New-StorageName -BaseName "stg$($rg -replace '-','')"

    Write-Host "  • $rgName/$storageName ... " -NoNewline

    New-AzStorageAccount `
        -ResourceGroupName  $rgName `
        -Name               $storageName `
        -Location           $location `
        -SkuName            'Standard_LRS' `
        -Kind               'StorageV2' `
        -MinimumTlsVersion  'TLS1_2' `
        -AllowBlobPublicAccess $false | Out-Null

    Write-Host "created" -ForegroundColor Green
}

# 5b: Named resources from resource-level override maps
foreach ($key in $resourceOverrideKeys) {
    $parts        = $key -split '/', 2
    $rgName       = "$rgPrefix$($parts[0])"
    $resourceName = $parts[1]

    $storageName = ($resourceName -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($storageName.Length -gt 24) { $storageName = $storageName.Substring(0, 24) }
    if ($storageName.Length -lt 3) { $storageName = "stg$storageName" }

    Write-Host "  • $rgName/$storageName (override key: $key) ... " -NoNewline

    $existing = Get-AzStorageAccount -ResourceGroupName $rgName -Name $storageName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "exists" -ForegroundColor DarkGray
        continue
    }

    $rgExists = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if (-not $rgExists) {
        New-AzResourceGroup -Name $rgName -Location $location -Force | Out-Null
        Write-Host "(created RG) " -NoNewline
    }

    New-AzStorageAccount `
        -ResourceGroupName  $rgName `
        -Name               $storageName `
        -Location           $location `
        -SkuName            'Standard_LRS' `
        -Kind               'StorageV2' `
        -MinimumTlsVersion  'TLS1_2' `
        -AllowBlobPublicAccess $false | Out-Null

    Write-Host "created" -ForegroundColor Green
}

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Staging complete." -ForegroundColor Cyan
Write-Host " Subscription: $subscriptionName ($subscriptionId)" -ForegroundColor Cyan
Write-Host ""
Write-Host " Next steps:" -ForegroundColor Cyan
Write-Host "   2. Deploy policies:  .\2_Deploy_Tag_Policies.ps1" -ForegroundColor White
Write-Host "   3. Validate tags:    .\3_Validate_Tag_Enforcement.ps1 -SubscriptionId $subscriptionId" -ForegroundColor White
Write-Host "   4. Break tags:       .\4_Modify_Tags.ps1 -SubscriptionId $subscriptionId" -ForegroundColor White
Write-Host "   5. Validate again:   .\3_Validate_Tag_Enforcement.ps1 -SubscriptionId $subscriptionId" -ForegroundColor White
Write-Host "   6. Tear down:        .\5_Destroy_Test_Infrastructure.ps1" -ForegroundColor White
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

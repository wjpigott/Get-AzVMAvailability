param(
    [Parameter(Mandatory = $true)]
    [string]$ManagementGroupId,

    [Parameter(Mandatory = $true)]
    [string]$QuotaGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter(Mandatory = $true)]
    [string]$ResourceName,

    [Parameter(Mandatory = $true)]
    [long]$TargetLimit,

    [int]$MaxPollAttempts = 20,
    [int]$PollIntervalSeconds = 10
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2025-09-01'
$resourceProvider = 'Microsoft.Compute'

function Get-ArmBearerToken {
    $tokenResult = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
    if ($tokenResult.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $tokenResult.Token).Password
    }
    return $tokenResult.Token
}

function Get-AllocationUri {
    param(
        [string]$ManagementGroupId,
        [string]$SubscriptionId,
        [string]$QuotaGroupName,
        [string]$ResourceProvider,
        [string]$Region,
        [string]$ApiVersion
    )

    $base = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupId/subscriptions/$SubscriptionId/providers/Microsoft.Quota/groupQuotas/$QuotaGroupName/resourceProviders/$ResourceProvider/quotaAllocations/$Region"
    return ($base + "?api-version=$ApiVersion")
}

function Get-RequestListUri {
    param(
        [string]$ManagementGroupId,
        [string]$SubscriptionId,
        [string]$QuotaGroupName,
        [string]$ResourceProvider,
        [string]$Region,
        [string]$ApiVersion
    )

    $filter = [uri]::EscapeDataString("location eq $Region")
    $base = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupId/subscriptions/$SubscriptionId/providers/Microsoft.Quota/groupQuotas/$QuotaGroupName/resourceProviders/$ResourceProvider/quotaAllocationRequests"
    return ($base + "?api-version=$ApiVersion&`$filter=$filter")
}

function Get-RequestUri {
    param(
        [string]$ManagementGroupId,
        [string]$SubscriptionId,
        [string]$QuotaGroupName,
        [string]$ResourceProvider,
        [string]$RequestId,
        [string]$ApiVersion
    )

    $base = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupId/subscriptions/$SubscriptionId/providers/Microsoft.Quota/groupQuotas/$QuotaGroupName/resourceProviders/$ResourceProvider/quotaAllocationRequests/$RequestId"
    return ($base + "?api-version=$ApiVersion")
}

function Get-CurrentAllocation {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$ResourceName
    )

    $response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
    return $response.value | Where-Object { $_.properties.resourceName -ieq $ResourceName }
}

$bearer = Get-ArmBearerToken
$headers = @{ Authorization = "Bearer $bearer" }
$patchHeaders = @{ Authorization = "Bearer $bearer"; 'Content-Type' = 'application/json' }

$allocationUri = Get-AllocationUri -ManagementGroupId $ManagementGroupId -SubscriptionId $SubscriptionId -QuotaGroupName $QuotaGroupName -ResourceProvider $resourceProvider -Region $Region -ApiVersion $apiVersion
$requestListUri = Get-RequestListUri -ManagementGroupId $ManagementGroupId -SubscriptionId $SubscriptionId -QuotaGroupName $QuotaGroupName -ResourceProvider $resourceProvider -Region $Region -ApiVersion $apiVersion

Write-Host "Allocation URI: $allocationUri" -ForegroundColor DarkGray
Write-Host "Request List URI: $requestListUri" -ForegroundColor DarkGray

$before = Get-CurrentAllocation -Uri $allocationUri -Headers $headers -ResourceName $ResourceName
if (-not $before) {
    throw "ResourceName '$ResourceName' not found in quotaAllocations/$Region for subscription $SubscriptionId"
}

Write-Host "Before: resource=$ResourceName limit=$($before.properties.limit) shareableQuota=$($before.properties.shareableQuota) region=$Region" -ForegroundColor Cyan

$patchBody = @{
    properties = @{
        value = @(
            @{
                properties = @{
                    resourceName = $ResourceName
                    limit = $TargetLimit
                }
            }
        )
    }
} | ConvertTo-Json -Depth 10

$requestId = $null
try {
    $patchResponse = Invoke-WebRequest -Uri $allocationUri -Headers $patchHeaders -Method Patch -Body $patchBody -ErrorAction Stop
    Write-Host "PATCH accepted: HTTP $($patchResponse.StatusCode)" -ForegroundColor Yellow
} catch {
    $errorMessage = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        $errorMessage = $_.ErrorDetails.Message
    }

    if ($errorMessage -match 'EntityAlreadyExists' -and $errorMessage -match 'request id:\s*([0-9a-fA-F-]{36})') {
        $requestId = $Matches[1]
        Write-Host "Found in-progress request: $requestId" -ForegroundColor Yellow
    } else {
        throw
    }
}

if (-not $requestId) {
    $requestList = Invoke-RestMethod -Uri $requestListUri -Headers $headers -Method Get -ErrorAction Stop
    $candidate = $requestList.value |
        Where-Object {
            (
                $_.requestedResource -and
                $_.requestedResource.properties -and
                $_.requestedResource.properties.name -and
                $_.requestedResource.properties.name.value -ieq $ResourceName
            ) -or (
                $_.properties -and
                $_.properties.requestedResource -and
                $_.properties.requestedResource.properties -and
                $_.properties.requestedResource.properties.name -and
                $_.properties.requestedResource.properties.name.value -ieq $ResourceName
            )
        } |
        Sort-Object {
            if ($_.requestProperties -and $_.requestProperties.requestSubmitTime) {
                [datetime]$_.requestProperties.requestSubmitTime
            } elseif ($_.properties -and $_.properties.requestSubmitTime) {
                [datetime]$_.properties.requestSubmitTime
            } else {
                [datetime]::MinValue
            }
        } -Descending |
        Select-Object -First 1

    if ($candidate) {
        $requestId = $candidate.name
        Write-Host "Latest request id: $requestId" -ForegroundColor Yellow
    }
}

if ($requestId) {
    $requestUri = Get-RequestUri -ManagementGroupId $ManagementGroupId -SubscriptionId $SubscriptionId -QuotaGroupName $QuotaGroupName -ResourceProvider $resourceProvider -RequestId $requestId -ApiVersion $apiVersion
    for ($i = 1; $i -le $MaxPollAttempts; $i++) {
        $statusResponse = Invoke-RestMethod -Uri $requestUri -Headers $headers -Method Get -ErrorAction Stop

        $state = $null
        if ($statusResponse.provisioningState) {
            $state = $statusResponse.provisioningState
        } elseif ($statusResponse.properties -and $statusResponse.properties.provisioningState) {
            $state = $statusResponse.properties.provisioningState
        }

        Write-Host "Poll ${i}/${MaxPollAttempts}: requestId=$requestId state=$state" -ForegroundColor DarkCyan

        if ($state -in @('Succeeded', 'Failed', 'Canceled', 'Invalid', 'Escalated')) {
            break
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

$after = Get-CurrentAllocation -Uri $allocationUri -Headers $headers -ResourceName $ResourceName
Write-Host "After:  resource=$ResourceName limit=$($after.properties.limit) shareableQuota=$($after.properties.shareableQuota) region=$Region" -ForegroundColor Green

if ($after.properties.limit -eq $TargetLimit) {
    Write-Host "Result: SUCCESS (allocation reached target limit $TargetLimit)" -ForegroundColor Green
} else {
    Write-Host "Result: PENDING/DIFFERENT (current limit $($after.properties.limit), target $TargetLimit)" -ForegroundColor Yellow
}

<#
Example:

pwsh .\examples\QuotaGroup-AllocationRequest-Example.ps1 \
    -ManagementGroupId <management-group-id> \
    -QuotaGroupName <quota-group-name> \
    -SubscriptionId <subscription-id-guid> \
  -Region centralus \
  -ResourceName standardbsfamily \
  -TargetLimit 79
#>

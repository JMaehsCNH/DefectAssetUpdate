
# === CONFIGURATION ===
$jiraBaseUrl = "https://cnhpd.atlassian.net"
$jiraEmail = "john.maehs@cnh.com"
$jiraToken = $env:jiraToken  # Or paste your token as a string here
$projectKey = "PREC"
$issueType = "Bug"

# GSS External API Keys
$subsKeyGSSProd = $env:subsKeyGSSProd
$subsKeyGSSMkt = $env:subsKeyGSSMkt

# === HEADERS ===
$headers = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$jiraEmail`:$jiraToken"))
    Accept = "application/json"
    "Content-Type" = "application/json"
}
$headerExtProd = @{ 'Ocp-Apim-Subscription-Key' = $subsKeyGSSProd }
$headerExtMkt  = @{ 'Ocp-Apim-Subscription-Key' = $subsKeyGSSMkt }

# === QUERY JIRA ISSUES (new /search/jql with nextPageToken) ===
$jql = "project = $projectKey AND issuetype = '$issueType'"
$searchUrl = "$jiraBaseUrl/rest/api/3/search/jql"

$body = @{
  jql        = $jql
  maxResults = 100
  fields     = @("customfield_13087","customfield_13089")  # VIN + companyName (adjust if needed)
} 

$allIssues = @()
$nextPageToken = $null

do {
    $payload = $body.Clone()
    if ($nextPageToken) { $payload["nextPageToken"] = $nextPageToken }

    $json = $payload | ConvertTo-Json -Depth 5
    $resp = Invoke-RestMethod -Uri $searchUrl -Method Post -Headers $headers -Body $json

    if ($resp.issues) { $allIssues += $resp.issues }

    # New pagination model
    if ($resp.isLast -eq $true) {
        $nextPageToken = $null
    } else {
        $nextPageToken = $resp.nextPageToken
    }
} while ($nextPageToken)

# Now iterate all issues as before
foreach ($issue in $allIssues) {
    $issueId = $issue.id
    $vin     = $issue.fields.customfield_13087
    Write-Host "`n🔍 Processing VIN: $vin (Jira ID: $issueId)"

    # ✅ Build GSS API URLs
    $urlProd = "https://euevoapi010.azure-api.net/gssp/core/v1/assets/$($vin)?domain=AG&assetIdType=VIN&metrics=ENG_HOURS&showPosition=True&showBundleVersion=True&showSource=true"
    $urlMkt  = "https://euevoapipv010.azure-api.net/gsss/core/v1/assets/$($vin)?domain=AG&assetIdType=VIN&metrics=ENG_HOURS&showPosition=True&showBundleVersion=True&showSource=true"

    # API calls...
    try { $dataProd = Invoke-RestMethod -Uri $urlProd -Headers $headerExtProd -Method Get } catch { $dataProd = $null }
    try { $dataMkt  = Invoke-RestMethod -Uri $urlMkt  -Headers $headerExtMkt  -Method Get } catch { $dataMkt  = $null }

    if (-not $dataProd -and -not $dataMkt) {
        Write-Host "❌ No data from either API for VIN $vin"
        continue
    }

    if ($dataProd -and -not $dataMkt) { $chosen = $dataProd; $envType = "PROD" }
    elseif ($dataMkt -and -not $dataProd) { $chosen = $dataMkt; $envType = "NON-PROD" }
    else {
        $chosen = if ($dataProd.time -ge $dataMkt.time) { $dataProd } else { $dataMkt }
        $envType = if ($chosen -eq $dataProd) { "PROD" } else { "NON-PROD" }
    }
    Write-Host "→ Latitude: $($chosen.pos.lat)"
    Write-Host "→ Longitude: $($chosen.pos.lon)"
    Write-Host "→ Engine Hours: $($chosen.metrics.value.value)"
    Write-Host "→ Archived: $($chosen.archived)"

    
    if ($issue.fields.customfield_13089) {
        Write-Host "⚠️ Skipping $vin because customfield_13089 (companyName) is already populated."
        continue
    }

    $updateFields = @{
    
        fields = @{
            "customfield_13088" = $chosen.ceqId
            "customfield_13089" = $chosen.companyName
            "customfield_13094" = $chosen.devices.tdac
            "customfield_13318" = $chosen.devices.deviceBundleVersion

        }
    } | ConvertTo-Json -Depth 10


    try {
        Invoke-RestMethod -Uri "$jiraBaseUrl/rest/api/3/issue/$issueId" -Method Put -Headers $headers -Body $updateFields
        Write-Host "✅ Updated $vin (Issue $issueId)"
    } catch {
        Write-Host ("❌ Failed to update {0}: {1}" -f $vin, $_.Exception.Message)
    }
}

# Fail fast on errors so we see the first real issue
$ErrorActionPreference = 'Stop'

# === CONFIGURATION ===
$jiraBaseUrl = "https://cnhpd.atlassian.net"
$jiraEmail   = "john.maehs@cnh.com"
$jiraToken   = $env:jiraToken          # GitHub secret
$projectKey  = "PREC"
$issueType   = "Bug"

# GSS External API Keys
$subsKeyGSSProd = $env:subsKeyGSSProd
$subsKeyGSSMkt  = $env:subsKeyGSSMkt

# === HEADERS ===
$headers = @{
  Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$jiraEmail`:$jiraToken"))
  Accept        = "application/json"
  "Content-Type"= "application/json"
}
$headerExtProd = @{ 'Ocp-Apim-Subscription-Key' = $subsKeyGSSProd }
$headerExtMkt  = @{ 'Ocp-Apim-Subscription-Key' = $subsKeyGSSMkt }

# --- Quick secret sanity ---
Write-Host "🔐 Email: $jiraEmail"
if ([string]::IsNullOrWhiteSpace($jiraToken)) {
  Write-Host "❌ jiraToken is empty! Check your GitHub Action secrets/env."
  exit 1
} else {
  Write-Host "🔐 jiraToken length: $($jiraToken.Length)"
}

# === QUERY JIRA ISSUES (new /search/jql with nextPageToken) ===
$jql = "project = PREC AND issuetype = 'Bug'"
$searchUrl = "$jiraBaseUrl/rest/api/3/search/jql"

$body = @{
  jql        = $jql
  maxResults = 100
  fields     = @("customfield_13087","customfield_13089")  # VIN + companyName (adjust if needed)
}

Write-Host "🔎 JQL: $jql"
Write-Host "🌐 Site: $jiraBaseUrl"
Write-Host "👤 User: $jiraEmail"

$allIssues = @()
$nextPageToken = $null
$searchPage = 0

do {
  $searchPage++
  $payload = $body.Clone()
  if ($nextPageToken) { $payload["nextPageToken"] = $nextPageToken }

  $json = $payload | ConvertTo-Json -Depth 5
  Write-Host "`n📄 Search page $searchPage (nextPageToken=$nextPageToken)"
  try {
    $resp = Invoke-RestMethod -Uri $searchUrl -Method Post -Headers $headers -Body $json
  } catch {
    Write-Host "❌ Search failed."
    if ($_.Exception.Response) {
      $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
      $errBody = $sr.ReadToEnd()
      Write-Host $errBody
    } else {
      Write-Host $_.Exception.Message
    }
    throw
  }

  $count = @($resp.issues).Count
  Write-Host "➡️  Retrieved $count issues in this page."
  if ($resp.issues) { $allIssues += $resp.issues }

  if ($resp.isLast -eq $true) {
    $nextPageToken = $null
  } else {
    $nextPageToken = $resp.nextPageToken
  }
} while ($nextPageToken)

Write-Host "`n📊 Total issues fetched: $($allIssues.Count)"
if ($allIssues.Count -eq 0) {
  Write-Host "ℹ️ No issues matched your JQL. Double-check project, issue type, and filters."
  exit 0
}

# === PROCESS ISSUES ===
foreach ($issue in $allIssues) {
  $issueId = $issue.id
  $issueKey = $issue.key
  $vin = $issue.fields.customfield_13087
  Write-Host "`n🔍 Processing: $issueKey (ID: $issueId)  VIN: $vin"

  # --- B) Check my permission to edit this issue ---
  $permUrl = "$jiraBaseUrl/rest/api/3/mypermissions?issueId=$issueId"
  try {
    $perm = Invoke-RestMethod -Uri $permUrl -Method Get -Headers $headers
    $canEdit = $perm.permissions.EDIT_ISSUES.havePermission
    Write-Host "🔑 Edit permission: $canEdit"
    if (-not $canEdit) {
      Write-Host "❌ No 'Edit Issues' permission on $issueKey. Skipping."
      continue
    }
  } catch {
    Write-Host "⚠️ Failed to check permissions for $issueKey"
    if ($_.Exception.Response) {
      $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
      $errBody = $sr.ReadToEnd()
      Write-Host $errBody
    } else {
      Write-Host $_.Exception.Message
    }
    continue
  }

  # --- C1) Map names ↔ IDs to confirm customfield IDs are right ---
  try {
    $withNames = Invoke-RestMethod -Uri "$jiraBaseUrl/rest/api/3/issue/$issueId?expand=names" `
                                   -Headers $headers -Method Get
    Write-Host "🧭 Field name map:"
    Write-Host "    customfield_13087 => $($withNames.names.customfield_13087)"
    Write-Host "    customfield_13089 => $($withNames.names.customfield_13089)"
    Write-Host "    customfield_13088 => $($withNames.names.customfield_13088)"
    Write-Host "    customfield_13094 => $($withNames.names.customfield_13094)"
    Write-Host "    customfield_13318 => $($withNames.names.customfield_13318)"
  } catch {
    Write-Host "⚠️ Could not fetch names map; continuing."
  }

  # --- C2) Check which fields are editable on this issue ---
  try {
    $editMeta = Invoke-RestMethod -Uri "$jiraBaseUrl/rest/api/3/issue/$issueId/editmeta" `
                                  -Headers $headers -Method Get
    $editable = $editMeta.fields.PSObject.Properties.Name
    $editableSample = ($editable | Select-Object -First 20) -join ", "
    Write-Host "🛠️  Editable fields (sample): $editableSample"
    $requiredFields = @('customfield_13088','customfield_13089','customfield_13094','customfield_13318')
    foreach ($f in $requiredFields) {
      if ($editable -notcontains $f) {
        Write-Host "⚠️ $f is NOT editable on $issueKey (may be wrong context/screen)."
      } else {
        Write-Host "✅ $f is editable."
      }
    }
  } catch {
    Write-Host "⚠️ Could not fetch editmeta; continuing."
  }

  # --- External API calls (your existing logic) ---
  $urlProd = "https://euevoapi010.azure-api.net/gssp/core/v1/assets/$($vin)?domain=AG&assetIdType=VIN&metrics=ENG_HOURS&showPosition=True&showBundleVersion=True&showSource=true"
  $urlMkt  = "https://euevoapipv010.azure-api.net/gsss/core/v1/assets/$($vin)?domain=AG&assetIdType=VIN&metrics=ENG_HOURS&showPosition=True&showBundleVersion=True&showSource=true"

  try { $dataProd = Invoke-RestMethod -Uri $urlProd -Headers $headerExtProd -Method Get } catch { $dataProd = $null }
  try { $dataMkt  = Invoke-RestMethod -Uri $urlMkt  -Headers $headerExtMkt  -Method Get } catch { $dataMkt  = $null }

  if (-not $dataProd -and -not $dataMkt) {
    Write-Host "❌ No data from either API for VIN $vin"
    continue
  }

  if     ($dataProd -and -not $dataMkt) { $chosen = $dataProd; $envType = "PROD" }
  elseif ($dataMkt  -and -not $dataProd){ $chosen = $dataMkt;  $envType = "NON-PROD" }
  else {
    $chosen = if ($dataProd.time -ge $dataMkt.time) { $dataProd } else { $dataMkt }
    $envType = if ($chosen -eq $dataProd) { "PROD" } else { "NON-PROD" }
  }

  # Defensive logs in case shapes vary
  Write-Host "🌎 Source chosen: $envType"
  Write-Host ("→ Latitude: {0}"  -f ($chosen.pos.lat   | Out-String).Trim())
  Write-Host ("→ Longitude: {0}" -f ($chosen.pos.lon   | Out-String).Trim())
  Write-Host ("→ Engine Hours: {0}" -f ($chosen.metrics.value.value | Out-String).Trim())
  Write-Host ("→ Archived: {0}"     -f ($chosen.archived | Out-String).Trim())
  Write-Host ("→ ceqId: {0}"        -f ($chosen.ceqId    | Out-String).Trim())
  Write-Host ("→ companyName: {0}"  -f ($chosen.companyName | Out-String).Trim())
  if ($chosen.devices) {
    Write-Host ("→ devices.tdac: {0}"                 -f ($chosen.devices.tdac | Out-String).Trim())
    Write-Host ("→ devices.deviceBundleVersion: {0}"  -f ($chosen.devices.deviceBundleVersion | Out-String).Trim())
  } else {
    Write-Host "→ devices: (null)"
  }

  # Skip if already populated (your rule)
  if ($issue.fields.customfield_13089) {
    Write-Host "⚠️ Skipping $issueKey because customfield_13089 (companyName) is already populated."
    continue
  }

  # --- D) Build update payload (omit nulls) ---
  $fieldsToSet = @{}
  if ($chosen.ceqId)                                   { $fieldsToSet["customfield_13088"] = $chosen.ceqId }
  if ($chosen.companyName)                             { $fieldsToSet["customfield_13089"] = $chosen.companyName }
  if ($chosen.devices -and $chosen.devices.tdac)       { $fieldsToSet["customfield_13094"] = $chosen.devices.tdac }
  if ($chosen.devices -and $chosen.devices.deviceBundleVersion) { $fieldsToSet["customfield_13318"] = $chosen.devices.deviceBundleVersion }

  if ($fieldsToSet.Keys.Count -eq 0) {
    Write-Host "⚠️ Nothing to update for $issueKey (all values null/missing)."
    continue
  }

  $updateFields = @{ fields = $fieldsToSet } | ConvertTo-Json -Depth 10
  Write-Host "🧾 Payload to Jira:"
  Write-Host $updateFields

  # --- E) PUT with visible HTTP details ---
  $updateUrl = "$jiraBaseUrl/rest/api/3/issue/$issueId"
  try {
    $respUpd = Invoke-WebRequest -Uri $updateUrl -Method Put -Headers $headers -Body $updateFields
    Write-Host "✅ Updated $issueKey (HTTP $($respUpd.StatusCode))"
  } catch {
    Write-Host "❌ Failed to update $issueKey"
    if ($_.Exception.Response) {
      $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
      $errBody = $sr.ReadToEnd()
      $code = [int]$_.Exception.Response.StatusCode
      $desc = $_.Exception.Response.StatusDescription
      Write-Host "HTTP $code $desc"
      Write-Host $errBody
    } else {
      Write-Host $_.Exception.Message
    }
    continue
  }
}

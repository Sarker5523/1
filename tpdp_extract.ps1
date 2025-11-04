<#=====================================================================
  ThePornDB Incremental Batch Extractor – SLUG + VIDEO_ID SUPPORT
  - Minimal scene_details.json (only IDs)
  - Full performer.json & site.json (deduped)
  - Handles slug OR video_id
  - Output uses slug if present, else video_id
  - Handles null IDs, $PID conflict, whitespace, case
  - Every SUCCESS = entry in file
  - Removes null/empty fields
  - Pretty JSON output
=====================================================================#>

# ---------- CONFIG ----------
$TOKEN = 'Aor5JIDSkxOhmXmNAOYP5Gnr73u7u3UPJZYaevBT2558d467'
$InputFile = 'video.json'
$OutputFile = 'scene_details.json'
$FailedFile = 'failed_entry.json'
$PerformerFile = 'performer.json'
$SiteFile = 'site.json'
$MaxRetries = 3
$DelayBetween = 500 # ms
# ----------------------------

# === Global collections for full details ===
$AllPerformers = @{}   # _id → full performer object
$AllSites = @{}        # id → full site object

# === Helper: Clean string (trim + normalize) ===
function Clean-Id {
    param($id)
    if (-not $id) { return $null }
    return $id.ToString().Trim().ToLower()
}

# === Validate input file ===
if (-not (Test-Path $InputFile)) {
    Write-Error "Missing '$InputFile' in script directory."
    exit 1
}

# === Load video.json ===
try {
    $videos = Get-Content $InputFile -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Failed to parse '$InputFile'. Invalid JSON?"
    exit 1
}

# === Normalize every video entry: add .video_id (raw) and .key (clean) ===
foreach ($v in $videos) {
    $rawKey = if ($v.slug) { $v.slug } else { $v.video_id }
    $cleanKey = Clean-Id $rawKey

    $v | Add-Member -MemberType NoteProperty -Name 'video_id' -Value $rawKey -Force
    $v | Add-Member -MemberType NoteProperty -Name 'key' -Value $cleanKey -Force
}

# === Load existing scene_details.json (if any) ===
$existing = @()
$existingMap = @{} # normalized key → object
if (Test-Path $OutputFile) {
    try {
        $existing = Get-Content $OutputFile -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($obj in $existing) {
            # Detect top-level key: slug or video_id (or old video_Id)
            $rawKey = $null
            if ($obj.slug) { $rawKey = $obj.slug }
            elseif ($obj.video_id) { $rawKey = $obj.video_id }
            elseif ($obj.video_Id) { $rawKey = $obj.video_Id }

            $cleanKey = Clean-Id $rawKey
            if ($cleanKey) {
                $existingMap[$cleanKey] = $obj
            }
        }
        Write-Host "Loaded $($existing.Count) existing entries from '$OutputFile'" -ForegroundColor DarkCyan
    }
    catch {
        Write-Warning "Failed to read '$OutputFile'. Starting fresh."
        $existing = @()
    }
}

# === Determine what needs fetching ===
$toFetch = @()
foreach ($v in $videos) {
    $rawKey = $v.video_id
    $cleanKey = $v.key
    $sceneId = $v.scene_id
    if (-not $sceneId) { $sceneId = $v.Itscene_id } # fix typo

    if (-not $cleanKey -or -not $sceneId) {
        Write-Warning "Skipping invalid entry: raw='$rawKey', clean='$cleanKey', scene_id='$sceneId'"
        continue
    }

    if (-not $existingMap.ContainsKey($cleanKey)) {
        $toFetch += [pscustomobject]@{
            raw_key   = $rawKey
            clean_key = $cleanKey
            scene_id  = $sceneId
        }
    }
}

$totalToFetch = $toFetch.Count
Write-Host "Found $totalToFetch new/missing scenes to fetch..." -ForegroundColor Yellow

if ($totalToFetch -eq 0) {
    Write-Host "Nothing to do! All scenes are up to date." -ForegroundColor Green
    pause
    exit 0
}

# === Helper: Remove null, empty string, empty array properties ===
function Remove-EmptyProperties {
    param([psobject]$obj)
    
    $props = $obj.PSObject.Properties | ForEach-Object { $_ }
    foreach ($prop in $props) {
        $value = $prop.Value
        $remove = $false

        if ($null -eq $value) { 
            $remove = $true 
        }
        elseif ($value -is [string] -and $value.Trim() -eq "") { 
            $remove = $true 
        }
        elseif ($value -is [array] -and $value.Count -eq 0) { 
            $remove = $true 
        }
        elseif ($value -is [psobject]) {
            Remove-EmptyProperties -obj $value
            if ($value.PSObject.Properties.Count -eq 0) { 
                $remove = $true 
            }
        }

        if ($remove) {
            $obj.PSObject.Properties.Remove($prop.Name)
        }
    }
}

# === Helper: Build MINIMAL scene object + collect full details ===
function New-SceneResult {
    param($rawKey, $cleanKey, $sceneId, $resp)

    $apiData = $resp.data

    # ------------------- COLLECT FULL PERFORMERS (SKIP NULL IDs + MALES) -------------------
    foreach ($perf in $apiData.performers) {
        $p = $perf.parent
        if ($null -eq $p._id) { continue }
        if ($p.extras.gender -ne 'Female') { continue }

        $performerId = $p._id
        if (-not $AllPerformers.ContainsKey($performerId)) {
            $extras = [pscustomobject]@{
                gender               = $p.extras.gender
                birthday             = $p.extras.birthday
                birthday_timestamp   = $p.extras.birthday_timestamp
                birthplace           = $p.extras.birthplace
                ethnicity            = $p.extras.ethnicity
                nationality          = $p.extras.nationality
                hair_colour          = $p.extras.hair_colour
                eye_colour           = $p.extras.eye_colour
                weight               = $p.extras.weight
                height               = $p.extras.height
                measurements         = $p.extras.measurements
                cupsize              = $p.extras.cupsize
                tattoos              = $p.extras.tattoos
                piercings            = $p.extras.piercings
                career_start_year    = $p.extras.career_start_year
            }
            Remove-EmptyProperties -obj $extras

            $AllPerformers[$performerId] = [pscustomobject]@{
                _id            = $performerId
                name           = $p.name
                disambiguation = $p.disambiguation
                bio            = $p.bio
                extras         = $extras
                image          = $p.image
            }
        }
    }

    # ------------------- COLLECT FULL SITE (SKIP NULL ID) -------------------
    $site = $apiData.site
    if ($null -eq $site.id) {
        Write-Warning "Scene $sceneId has no site.id – skipping site collection"
    }
    else {
        $siteId = $site.id
        if (-not $AllSites.ContainsKey($siteId)) {
            $network = $site.network
            $parent = $site.parent

            $networkObj = if ($network) { [pscustomobject]@{ id = $network.id; name = $network.name } } else { $null }
            $parentObj  = if ($parent)  { [pscustomobject]@{ id = $parent.id;  name = $parent.name }  } else { $null }

            $AllSites[$siteId] = [pscustomobject]@{
                id          = $siteId
                parent_id   = $site.parent_id
                network_id  = $site.network_id
                name        = $site.name
                description = $site.description
                logo        = $site.logo
                network     = $networkObj
                parent      = $parentObj
            }
            Remove-EmptyProperties -obj $AllSites[$siteId]
        }
    }

    # ------------------- BUILD MINIMAL RESULT -------------------
    $keyName = if ($videos[0].PSObject.Properties.Name -contains 'slug' -and $videos[0].slug) { 'slug' } else { 'video_id' }

    $result = [pscustomobject]@{
        $keyName = $rawKey
        data     = [pscustomobject]@{
            _id         = $apiData._id
            title       = $apiData.title
            description = $apiData.description
            date        = $apiData.date
            trailer     = $apiData.trailer
            background  = [pscustomobject]@{ full = $apiData.background.full }
            performers  = $apiData.performers |
                          Where-Object { $_.parent._id -and $_.parent.extras.gender -eq 'Female' } |
                          ForEach-Object { [pscustomobject]@{ parent = [pscustomobject]@{ _id = $_.parent._id } } }
            site        = $null
        }
    }

    if ($site.id) {
        $result.data.site = [pscustomobject]@{
            id          = $site.id
            parent_id   = $site.parent_id
            network_id  = $site.network_id
        }
    }

    # Clean everything
    Remove-EmptyProperties -obj $result.data.background
    if ($result.data.site) { Remove-EmptyProperties -obj $result.data.site }
    Remove-EmptyProperties -obj $result.data
    Remove-EmptyProperties -obj $result

    return $result
}

# === Fetch loop with retry & delay ===
$newResults = @()
$failedEntries = @()
$idx = 0

foreach ($item in $toFetch) {
    $idx++
    $rawKey = $item.raw_key
    $cleanKey = $item.clean_key
    $sceneId = $item.scene_id
    
    Write-Progress -Activity "Fetching new scenes" -Status "$idx / $totalToFetch ($rawKey)" -PercentComplete ($idx/$totalToFetch*100)

    $success = $false
    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        try {
            $uri = "https://api.theporndb.net/scenes/$sceneId`?add_to_collection=true"
            $headers = @{
                Authorization = "Bearer $TOKEN"
                Accept = 'application/json'
            }
            $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            
            $sceneObj = New-SceneResult -rawKey $rawKey -cleanKey $cleanKey -sceneId $sceneId -resp $resp
            $newResults += $sceneObj
            $success = $true
            Write-Host "[$idx] $rawKey → $sceneId OK" -ForegroundColor Green
            break
        }
        catch {
            if ($retry -lt $MaxRetries) {
                Write-Host "[$idx] $rawKey → $sceneId Retry $retry/$MaxRetries..." -ForegroundColor DarkYellow
                Start-Sleep -Milliseconds ($DelayBetween * $retry)
            }
            else {
                Write-Host "[$idx] $rawKey → $sceneId FAILED after $MaxRetries tries" -ForegroundColor Red
                Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor DarkRed

                $failedEntries += [pscustomobject]@{
                    raw_key   = $rawKey
                    clean_key = $cleanKey
                    scene_id  = $sceneId
                    error     = $_.Exception.Message
                }
            }
        }
    }
    Start-Sleep -Milliseconds $DelayBetween
}

Write-Host "`nFetch complete: $($newResults.Count) successful, $($failedEntries.Count) failed" -ForegroundColor Cyan

# === Merge: existing + new successful results (preserve video.json order) ===
$finalResults = @()
$seen = @{} # normalized key → true

foreach ($v in $videos) {
    $rawKey = $v.video_id
    $cleanKey = $v.key

    if (-not $cleanKey) { 
        Write-Warning "Skipping entry with invalid key: '$rawKey'"
        continue 
    }

    $obj = $null
    $keyName = if ($v.slug) { 'slug' } else { 'video_id' }

    if ($existingMap.ContainsKey($cleanKey)) {
        $obj = $existingMap[$cleanKey]
        # Replace old key with correct one
        $obj.PSObject.Properties.Remove('video_Id')  # old
        $obj.PSObject.Properties.Remove('slug')
        $obj.PSObject.Properties.Remove('video_id')
        $obj | Add-Member -MemberType NoteProperty -Name $keyName -Value $rawKey -Force
    }
    elseif ($newResults | Where-Object {
        $o = $_
        $k = if ($o.slug) { $o.slug } elseif ($o.video_id) { $o.video_id } else { $null }
        (Clean-Id $k) -eq $cleanKey
    }) {
        $obj = $newResults | Where-Object {
            $o = $_
            $k = if ($o.slug) { $o.slug } elseif ($o.video_id) { $o.video_id } else { $null }
            (Clean-Id $k) -eq $cleanKey
        } | Select-Object -First 1
        $obj.PSObject.Properties.Remove('video_Id')
        $obj.PSObject.Properties.Remove('slug')
        $obj.PSObject.Properties.Remove('video_id')
        $obj | Add-Member -MemberType NoteProperty -Name $keyName -Value $rawKey -Force
    }

    if ($obj) {
        if (-not $seen[$cleanKey]) {
            Remove-EmptyProperties -obj $obj
            $finalResults += $obj
            $seen[$cleanKey] = $true
            Write-Host "Added: $rawKey → $(if($obj.data._id){$obj.data._id}else{'NO_SCENE_ID'})" -ForegroundColor DarkGreen
        } else {
            Write-Warning "Duplicate normalized key '$cleanKey' (raw: '$rawKey') - skipping"
        }
    } else {
        Write-Warning "No data found for key '$rawKey' (normalized: '$cleanKey')"
    }
}

# === Write updated scene_details.json (MINIMAL) ===
try {
    $finalResults | ConvertTo-Json -Depth 20 | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Host "`nSUCCESS! Updated '$OutputFile' with $($finalResults.Count) total entries." -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to write '$OutputFile': $($_.Exception.Message)"
    exit 1
}

# === Write performer.json (deduped, sorted by _id) ===
if ($AllPerformers.Count -gt 0) {
    $sortedPerformers = $AllPerformers.Values | Sort-Object _id
    try {
        $sortedPerformers | ConvertTo-Json -Depth 20 | Out-File -FilePath $PerformerFile -Encoding UTF8
        Write-Host "Saved $($AllPerformers.Count) performers → '$PerformerFile'" -ForegroundColor Magenta
    }
    catch {
        Write-Error "Failed to write '$PerformerFile': $($_.Exception.Message)"
    }
}
else {
    Write-Host "No performers collected." -ForegroundColor Gray
    if (Test-Path $PerformerFile) { Remove-Item $PerformerFile -Force }
}

# === Write site.json (deduped, sorted by id) ===
if ($AllSites.Count -gt 0) {
    $sortedSites = $AllSites.Values | Sort-Object id
    try {
        $sortedSites | ConvertTo-Json -Depth 20 | Out-File -FilePath $SiteFile -Encoding UTF8
        Write-Host "Saved $($AllSites.Count) sites → '$SiteFile'" -ForegroundColor Magenta
    }
    catch {
        Write-Error "Failed to write '$SiteFile': $($_.Exception.Message)"
    }
}
else {
    Write-Host "No sites collected." -ForegroundColor Gray
    if (Test-Path $SiteFile) { Remove-Item $SiteFile -Force }
}

# === Write failed_entry.json ===
if ($failedEntries.Count -gt 0) {
    try {
        $failedEntries | ConvertTo-Json -Depth 5 | Out-File -FilePath $FailedFile -Encoding UTF8
        Write-Host "FAILED: $($failedEntries.Count) entries saved to '$FailedFile'" -ForegroundColor Red
    }
    catch {
        Write-Error "Failed to write '$FailedFile': $($_.Exception.Message)"
    }
}
else {
    Write-Host "No failed entries." -ForegroundColor Green
    if (Test-Path $FailedFile) { Remove-Item $FailedFile -Force }
}

# === Summary ===
Write-Host "`n=== SUMMARY ===" -ForegroundColor Magenta
Write-Host "Total from video.json: $($videos.Count)" -ForegroundColor White
Write-Host "Successfully processed: $($finalResults.Count)" -ForegroundColor Green
Write-Host "Failed: $($failedEntries.Count)" -ForegroundColor Red
Write-Host "Skipped (invalid): $($videos.Count - $finalResults.Count - $failedEntries.Count)" -ForegroundColor Yellow
Write-Host "Performers collected: $($AllPerformers.Count)" -ForegroundColor Magenta
Write-Host "Sites collected: $($AllSites.Count)" -ForegroundColor Magenta

# === Done ===
Write-Host "`nPress any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

<#
.SYNOPSIS
  Split a flat folder of gathered photos into upload-sized batches.

.DESCRIPTION
  A browser drag of several thousand files stalls. This breaks the folder into
  chunks small enough to upload reliably, and named so you can verify them
  afterwards.

  Two ways to split:

    Year   (default)  one folder per year, taken from each file's modified time.
                      Lets you check a year in Google Photos and compare counts.
                      A year with more than -Max files is split into -part2, -part3.
    Source            one folder per original folder, read from manifest.csv. Use
                      this when some folders matter more than others and you want
                      to upload them in your own order, knowing what each one is.
    Count             plain batch-001, batch-002 of -Max files each.

  Videos go into their own folders either way. They are a small share of the
  file count and most of the bytes, so they upload on a completely different
  timescale and mixing them in makes progress impossible to read.

  Files are MOVED within the same folder, so nothing is duplicated and it is
  near-instant. manifest.csv is left where it is.

.EXAMPLE
  .\Split-ForUpload.ps1 -Source C:\photos-for-google

.EXAMPLE
  .\Split-ForUpload.ps1 -Source C:\photos-for-google -By Count -Max 500

.EXAMPLE
  .\Split-ForUpload.ps1 -Source C:\photos-for-google -Undo
  Pull everything back into the top folder and remove the batch folders.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Source,

    [ValidateSet('Year','Count','Source')]
    [string] $By = 'Year',

    # Most files in one folder. Chrome gets unreliable past roughly a thousand.
    [int] $Max = 800,

    # Put videos in their own folders.
    [bool] $SeparateVideo = $true,

    # Move everything back to the top and delete the batch folders.
    [switch] $Undo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not (Test-Path -LiteralPath $Source)) { throw "No such folder: $Source" }
$Source = (Convert-Path -LiteralPath $Source)

$VideoExt = @('.mov','.mp4','.m4v','.avi','.3gp','.3g2','.mpg','.mpeg','.mts','.m2ts','.wmv','.mkv')
$Keep     = @('manifest.csv','duplicates-left-in-place.txt')

function Format-Size([double]$Bytes) {
    foreach ($u in 'B','KB','MB','GB','TB') {
        if ($Bytes -lt 1024 -or $u -eq 'TB') { return ('{0:N1} {1}' -f $Bytes, $u) }
        $Bytes = $Bytes / 1024
    }
}

# ------------------------------------------------------------------------ undo

if ($Undo) {
    $dirs = @(Get-ChildItem -LiteralPath $Source -Directory)
    if ($dirs.Count -eq 0) { Write-Host 'No batch folders here. Nothing to undo.'; return }
    $moved = 0; $clash = 0
    foreach ($d in $dirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File)) {
            $target = Join-Path $Source $f.Name
            if (Test-Path -LiteralPath $target) { $clash++; continue }
            Move-Item -LiteralPath $f.FullName -Destination $target
            $moved++
        }
        if (@(Get-ChildItem -LiteralPath $d.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $d.FullName -Force
        }
    }
    Write-Host ("Moved {0:N0} files back to {1}" -f $moved, $Source)
    if ($clash) { Write-Host ("{0:N0} were left in place because a file of that name is already at the top" -f $clash) }
    return
}

# ----------------------------------------------------------------------- split

$files = @(Get-ChildItem -LiteralPath $Source -File | Where-Object { $Keep -notcontains $_.Name })
if ($files.Count -eq 0) { throw "No loose files in $Source. Already split? Use -Undo to undo." }

Write-Host ''
Write-Host ("{0:N0} files, {1}, splitting by {2}, at most {3:N0} per folder" -f `
    $files.Count, (Format-Size (($files | Measure-Object Length -Sum).Sum)), $By, $Max)
Write-Host ''

# Source mode needs the manifest, which maps each gathered file back to where it
# came from. Build destination-filename -> label before the assignment loop.
$srcLabel = @{}
if ($By -eq 'Source') {
    $manifestPath = Join-Path $Source 'manifest.csv'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Source mode needs $manifestPath, which Collect-Photos.ps1 writes."
    }
    $bad = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($row in (Import-Csv -LiteralPath $manifestPath)) {
        $dir = [System.IO.Path]::GetDirectoryName($row.Source)
        if (-not $dir) { continue }
        # Last two path segments read better than either one alone:
        # "Family Pics-beach" beats "beach", and beats the whole path.
        $parts = @($dir -split '\\' | Where-Object { $_ -ne '' })
        $take  = if ($parts.Count -ge 2) { $parts[-2..-1] } else { $parts }
        $label = ($take -join '-')
        foreach ($c in $bad) { $label = $label.Replace([string]$c, '') }
        if ($label.Length -gt 60) { $label = $label.Substring(0, 60) }
        $srcLabel[[System.IO.Path]::GetFileName($row.Destination)] = $label
    }
    Write-Host ("manifest maps {0:N0} files to {1:N0} source folders" -f `
        $srcLabel.Count, (@($srcLabel.Values | Sort-Object -Unique)).Count)
}

# Assign each file a bucket name, then number the parts inside oversized buckets.
$assign = @{}
foreach ($f in $files) {
    $isVid = $VideoExt -contains $f.Extension.ToLowerInvariant()
    $kind  = if ($SeparateVideo -and $isVid) { 'video' } else { 'photos' }
    if ($By -eq 'Source') {
        # Source folders are already coherent, so video is not split out again.
        $bucket = if ($srcLabel.ContainsKey($f.Name)) { $srcLabel[$f.Name] } else { 'unknown-source' }
    } elseif ($By -eq 'Year') {
        $y = $f.LastWriteTime.Year
        # A modified time in the current year means the timestamp came from a copy,
        # not from the camera. Those get their own folder rather than a wrong year.
        $bucket = if ($y -lt 1990 -or $y -ge (Get-Date).Year) { "$kind-unknown-date" } else { "$kind-$y" }
    } else {
        $bucket = $kind
    }
    if (-not $assign.ContainsKey($bucket)) { $assign[$bucket] = New-Object System.Collections.ArrayList }
    $assign[$bucket].Add($f) | Out-Null
}

$made = New-Object System.Collections.ArrayList
foreach ($bucket in ($assign.Keys | Sort-Object)) {
    $items = @($assign[$bucket] | Sort-Object Name)
    $partCount = [math]::Ceiling($items.Count / [double]$Max)
    for ($p = 0; $p -lt $partCount; $p++) {
        $slice = @($items[($p * $Max) .. ([math]::Min(($p + 1) * $Max, $items.Count) - 1)])
        $name = if ($By -eq 'Count') {
                    '{0}-batch-{1:d3}' -f $bucket, ($p + 1)
                } elseif ($partCount -gt 1) {
                    '{0}-part{1}' -f $bucket, ($p + 1)
                } else { $bucket }
        $dir = Join-Path $Source $name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $bytes = 0
        foreach ($f in $slice) {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $dir $f.Name)
            $bytes += $f.Length
        }
        $made.Add([PSCustomObject]@{ Folder = $name; Count = $slice.Count; Bytes = $bytes }) | Out-Null
    }
}

Write-Host 'Upload these one at a time, in this order (photos first, they are quick):'
Write-Host ''
foreach ($m in ($made | Sort-Object Folder)) {
    Write-Host ('  {0,-28} {1,6:N0} files  {2,10}' -f $m.Folder, $m.Count, (Format-Size $m.Bytes))
}
Write-Host ''
Write-Host ("{0} folders. After each one, check that year in Google Photos went up by about that count." -f $made.Count)
Write-Host ('Put it all back with:  .\Split-ForUpload.ps1 -Source "{0}" -Undo' -f $Source)

<#
.SYNOPSIS
  Find every photo and video on this machine and gather them into one folder,
  ready to drop into Google Photos.

.DESCRIPTION
  Four modes. Report is the default and changes nothing.

    Report   walk the drives, print what is out there, touch nothing
    Copy     copy them into -Dest, skipping byte-identical duplicates
    Move     same, but removes the original (see the warning below)
    Dates    check -Dest for images with no EXIF capture date

  Deduplicates by SHA256 while copying, so ten copies of the same photo across
  ten folders arrive once. Preserves each file's modified time, which is what
  Google Photos falls back on when a photo has no EXIF date. Writes a manifest
  CSV mapping every copied file back to where it came from, and re-reads that
  manifest on a later run so an interrupted job resumes instead of restarting.

.EXAMPLE
  .\Collect-Photos.ps1
  Report on every fixed drive. Read-only.

.EXAMPLE
  .\Collect-Photos.ps1 -Roots C:\Users\you -Mode Report

.EXAMPLE
  .\Collect-Photos.ps1 -Mode Copy
  Copy into Desktop\photos-for-google.

.EXAMPLE
  .\Collect-Photos.ps1 -Mode Dates
  How many of the gathered images will land under the upload date.

.NOTES
  Move is there because you asked for it, but a whole-drive crawl picks up
  images that belong to installed programs. Moving those breaks them. Run Report
  first, read the folder list, and only use Move if you are certain. Copy plus a
  later delete is the same outcome with an undo.

  Report, Copy and Move work on Windows PowerShell 5.1 and PowerShell 7.
  Dates needs System.Drawing, so run that one under Windows PowerShell 5.1
  (powershell.exe) rather than pwsh. No modules to install either way.
#>

[CmdletBinding()]
param(
    # Folders or drives to search. Default: every fixed drive on the machine.
    [string[]] $Roots,

    # Where the gathered files go.
    [string] $Dest = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'photos-for-google'),

    # Skip anything smaller than this. Icons, web thumbnails and sprites are tiny;
    # real photos, even from 1999, are rarely under 40 KB. Report prints a size
    # breakdown so you can judge before committing.
    [int] $MinKB = 40,

    [ValidateSet('Report','Copy','Move','Dates')]
    [string] $Mode = 'Report',

    # Include video files as well as stills.
    [bool] $IncludeVideo = $true,

    # Manifest CSV. Defaults to a file inside -Dest.
    [string] $Manifest,

    # Extra path fragments to skip, on top of the built-in list.
    [string[]] $ExcludeAlso = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- what counts

$PhotoExt = @(
    '.jpg','.jpeg','.jpe','.png','.gif','.tif','.tiff','.bmp','.heic','.heif','.webp',
    '.dng','.nef','.cr2','.cr3','.arw','.orf','.raf','.rw2','.pef','.srw','.sr2','.raw'
)
$VideoExt = @(
    '.mov','.mp4','.m4v','.avi','.3gp','.3g2','.mpg','.mpeg','.mts','.m2ts','.wmv','.mkv'
)
$WantExt = if ($IncludeVideo) { $PhotoExt + $VideoExt } else { $PhotoExt }
$WantSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in $WantExt) { [void]$WantSet.Add($e) }

# Path fragments that mean "this image belongs to software, not to you".
# Matched case-insensitively anywhere in the full path.
$Exclude = @(
    '\Windows\', '\Program Files', '\ProgramData\', '\WinSxS\', '\Package Cache\',
    '\AppData\Local\', '\AppData\LocalLow\', '\AppData\Roaming\',
    '$Recycle.Bin', '\System Volume Information', '\Recovery\',
    '\Temp\', '\Temporary Internet Files\', '\INetCache\', '\INetCookies\',
    '\node_modules\', '\.git\', '\.svn\', '\vendor\bundle\', '\site-packages\',
    '\Steam\', '\steamapps\', '\Epic Games\', '\Origin Games\', '\GOG Galaxy\',
    '\Battle.net\', '\Riot Games\',
    '\.dropbox.cache\', '\OneDriveTemp\', '\.thumbnails\', '\Thumbnails\',
    '\Album Artwork\', '\iPod Photo Cache\', '\Photo Cache\',
    '\User Data\Default\Cache\', '\Firefox\Profiles\', '\Safari\',
    '\Microsoft\Windows\Explorer\', '\Microsoft\Windows\Themes\',
    '\Adobe\Bridge\Cache\', '\Lightroom\', '\Previews.lrdata\',
    '\Anaconda3\', '\Miniconda3\', '\Python3', '\dotnet\', '\Unity\'
) + $ExcludeAlso

$DestFull = try { [System.IO.Path]::GetFullPath($Dest) } catch { $Dest }
if (-not $Manifest) { $Manifest = Join-Path $DestFull 'manifest.csv' }

# Never walk into the destination, or a re-run re-copies its own output.
function Test-Excluded([string]$Path) {
    if ($Path.StartsWith($DestFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    foreach ($frag in $Exclude) {
        if ($Path.IndexOf($frag, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Get-DefaultRoots {
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' |
        Select-Object -ExpandProperty DeviceID | ForEach-Object { "$_\" }
}

function Format-Size([double]$Bytes) {
    foreach ($u in 'B','KB','MB','GB','TB') {
        if ($Bytes -lt 1024 -or $u -eq 'TB') { return ('{0:N1} {1}' -f $Bytes, $u) }
        $Bytes = $Bytes / 1024
    }
}

# ------------------------------------------------- the walk (access-denied safe)

# Get-ChildItem -Recurse aborts or balloons on a whole drive. An explicit stack
# with try/catch per directory survives permission errors and long paths, and
# streams results instead of holding them all.
function Get-Candidates {
    param([string[]]$Roots, [long]$MinBytes)

    $stack = New-Object System.Collections.Stack
    foreach ($r in $Roots) {
        if (Test-Path -LiteralPath $r) { $stack.Push((Convert-Path -LiteralPath $r)) }
        else { Write-Warning "Skipping missing root: $r" }
    }

    $dirCount = 0
    $script:DeniedDirs = 0
    $script:LongPaths  = 0

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirCount++
        if ($dirCount % 500 -eq 0) {
            Write-Host ("`r  scanned {0:N0} folders..." -f $dirCount) -NoNewline
        }

        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                if (-not (Test-Excluded $sub)) {
                    # A reparse point can loop or lead off-volume. Skip them.
                    $attr = [System.IO.File]::GetAttributes($sub)
                    if (-not ($attr -band [System.IO.FileAttributes]::ReparsePoint)) {
                        $stack.Push($sub)
                    }
                }
            }
        } catch [System.UnauthorizedAccessException] { $script:DeniedDirs++ }
          catch [System.IO.PathTooLongException]     { $script:LongPaths++  }
          catch { }

        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                $ext = [System.IO.Path]::GetExtension($f)
                if (-not $WantSet.Contains($ext)) { continue }
                try {
                    $fi = New-Object System.IO.FileInfo($f)
                    if ($fi.Length -lt $MinBytes) { continue }
                    [PSCustomObject]@{
                        Path   = $f
                        Name   = $fi.Name
                        Ext    = $ext.ToLowerInvariant()
                        Bytes  = $fi.Length
                        Mtime  = $fi.LastWriteTime
                        Folder = $fi.DirectoryName
                    }
                } catch { }
            }
        } catch [System.UnauthorizedAccessException] { $script:DeniedDirs++ }
          catch [System.IO.PathTooLongException]     { $script:LongPaths++  }
          catch { }
    }
    Write-Host ("`r  scanned {0:N0} folders.      " -f $dirCount)
}

# ------------------------------------------------------------------- the modes

if (-not $Roots -or $Roots.Count -eq 0) { $Roots = Get-DefaultRoots }
$MinBytes = [long]$MinKB * 1024

Write-Host ''
Write-Host "Mode:    $Mode"
Write-Host ("Roots:   {0}" -f ($Roots -join ', '))
Write-Host "Dest:    $Dest"
Write-Host ("Minimum: {0} KB   Video: {1}" -f $MinKB, $IncludeVideo)
Write-Host ''

# ---------------------------------------------------------------------- Dates

if ($Mode -eq 'Dates') {
    if (-not (Test-Path -LiteralPath $DestFull)) { throw "Nothing at $DestFull yet. Run -Mode Copy first." }
    $Dest = $DestFull
    try { Add-Type -AssemblyName System.Drawing }
    catch { throw "This mode needs System.Drawing, which Windows PowerShell 5.1 has built in. Try: powershell.exe -File .\Collect-Photos.ps1 -Mode Dates" }
    $withDate = 0; $noDate = 0; $unreadable = 0
    $stills = @('.jpg','.jpeg','.jpe','.png','.tif','.tiff','.gif','.bmp')
    $files = [System.IO.Directory]::EnumerateFiles($Dest) |
             Where-Object { $stills -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() }
    $i = 0
    foreach ($f in $files) {
        $i++
        if ($i % 200 -eq 0) { Write-Host ("`r  checked {0:N0}..." -f $i) -NoNewline }
        $img = $null
        try {
            $img = [System.Drawing.Image]::FromFile($f)
            # 36867 = EXIF DateTimeOriginal
            if ($img.PropertyIdList -contains 36867) { $withDate++ } else { $noDate++ }
        } catch { $unreadable++ }
        finally { if ($img) { $img.Dispose() } }
    }
    Write-Host ("`r  checked {0:N0}.            " -f $i)
    Write-Host ''
    Write-Host ("{0,8:N0}  have an EXIF capture date, and will file correctly" -f $withDate)
    Write-Host ("{0,8:N0}  have none" -f $noDate)
    if ($unreadable) {
        Write-Host ("{0,8:N0}  could not be read here (HEIC and RAW need other tools; they may still be fine)" -f $unreadable)
    }
    Write-Host ''
    if ($noDate -gt 0) {
        Write-Host "The ones with no EXIF date fall back to the file's modified time, which this"
        Write-Host "script preserved. Google Photos uses that. Where the modified time is also"
        Write-Host "wrong, those photos land under the wrong date and have to be fixed by hand"
        Write-Host "in Google Photos afterwards."
    }
    return
}

# --------------------------------------------------------- Report / Copy / Move

Write-Host 'Walking. On a full drive this takes a few minutes.'
$found = @(Get-Candidates -Roots $Roots -MinBytes $MinBytes)

if ($found.Count -eq 0) {
    Write-Host 'Found nothing matching. Check -Roots and -MinKB.'
    return
}

$totalBytes = ($found | Measure-Object -Property Bytes -Sum).Sum
Write-Host ''
Write-Host ("{0:N0} candidate files, {1}" -f $found.Count, (Format-Size $totalBytes))
if ($script:DeniedDirs) { Write-Host ("  {0:N0} folders were not readable (normal; mostly system)" -f $script:DeniedDirs) }
if ($script:LongPaths)  { Write-Host ("  {0:N0} paths were too long for Windows to open" -f $script:LongPaths) }

Write-Host ''
Write-Host 'By type:'
$found | Group-Object Ext | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    $sz = ($_.Group | Measure-Object -Property Bytes -Sum).Sum
    Write-Host ('  {0,-8} {1,8:N0}  {2,12}' -f $_.Name, $_.Count, (Format-Size $sz))
}

Write-Host ''
Write-Host 'Biggest folders:'
$found | Group-Object Folder | ForEach-Object {
    [PSCustomObject]@{
        Folder = $_.Name
        Count  = $_.Count
        Bytes  = ($_.Group | Measure-Object -Property Bytes -Sum).Sum
    }
} | Sort-Object Bytes -Descending | Select-Object -First 20 | ForEach-Object {
    Write-Host ('  {0,8:N0}  {1,10}  {2}' -f $_.Count, (Format-Size $_.Bytes), $_.Folder)
}

Write-Host ''
Write-Host 'Size spread (lower -MinKB if real photos are hiding under the cut):'
$buckets = @(
    @{ Label = 'under 100 KB'; Min = 0;        Max = 102400 },
    @{ Label = '100 KB - 1 MB'; Min = 102400;  Max = 1048576 },
    @{ Label = '1 - 5 MB';      Min = 1048576; Max = 5242880 },
    @{ Label = 'over 5 MB';     Min = 5242880; Max = [long]::MaxValue }
)
foreach ($b in $buckets) {
    $n = @($found | Where-Object { $_.Bytes -ge $b.Min -and $_.Bytes -lt $b.Max }).Count
    Write-Host ('  {0,-16} {1,8:N0}' -f $b.Label, $n)
}

$nameClashes = @($found | Group-Object Name | Where-Object { $_.Count -gt 1 }).Count
Write-Host ''
Write-Host ("{0:N0} filenames appear more than once. Some are the same photo, some are not;" -f $nameClashes)
Write-Host 'the copy hashes every file, so identical ones arrive once and the rest get a suffix.'

if ($Mode -eq 'Report') {
    Write-Host ''
    Write-Host 'Report only. Nothing was read into, written to, or moved from anywhere.'
    Write-Host 'Read the folder list above. If it contains program folders, add them to'
    Write-Host '-ExcludeAlso before copying. Then:'
    Write-Host ''
    Write-Host ('  .\Collect-Photos.ps1 -Mode Copy -MinKB {0}' -f $MinKB)
    Write-Host ''
    return
}

# ----------------------------------------------------------------- the transfer

if ($Mode -eq 'Move') {
    Write-Host ''
    Write-Host 'MOVE removes the original. Images belonging to installed programs will break.' -ForegroundColor Yellow
    $ans = Read-Host 'Type MOVE in capitals to confirm, anything else to abort'
    if ($ans -ne 'MOVE') { Write-Host 'Aborted. Nothing changed.'; return }
}

New-Item -ItemType Directory -Path $DestFull -Force | Out-Null
$Dest = $DestFull

# Resume: anything already recorded in the manifest is done.
$seenHash = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$doneSrc  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$newManifest = $true
if (Test-Path -LiteralPath $Manifest) {
    $newManifest = $false
    try {
        foreach ($row in (Import-Csv -LiteralPath $Manifest)) {
            if ($row.Sha256) { [void]$seenHash.Add($row.Sha256) }
            if ($row.Source) { [void]$doneSrc.Add($row.Source) }
        }
        Write-Host ("Resuming: manifest already has {0:N0} files." -f $doneSrc.Count)
    } catch { Write-Warning "Could not read $Manifest ; starting a fresh one." }
}

$writer = New-Object System.IO.StreamWriter($Manifest, -not $newManifest, [System.Text.Encoding]::UTF8)
if ($newManifest) { $writer.WriteLine('Destination,Source,SizeBytes,LastWriteTime,Sha256') }

function Write-Row($dst, $src, $bytes, $mtime, $hash) {
    $q = { param($s) '"' + ($s -replace '"','""') + '"' }
    $writer.WriteLine(('{0},{1},{2},{3},{4}' -f `
        (& $q $dst), (& $q $src), $bytes, (& $q $mtime.ToString('yyyy-MM-dd HH:mm:ss')), (& $q $hash)))
}

$copied = 0; $dupes = 0; $failed = 0; $skipped = 0
$dupeList = New-Object System.Collections.ArrayList
$failList = New-Object System.Collections.ArrayList
$copiedBytes = 0
$idx = 0

foreach ($f in $found) {
    $idx++
    if ($idx % 25 -eq 0 -or $idx -eq $found.Count) {
        Write-Host ("`r  {0:N0}/{1:N0}  copied {2:N0}  duplicates skipped {3:N0}  {4}   " -f `
            $idx, $found.Count, $copied, $dupes, (Format-Size $copiedBytes)) -NoNewline
    }

    if ($doneSrc.Contains($f.Path)) { $skipped++; continue }

    # Get-FileHash writes a non-terminating error that slips past a plain try/catch,
    # so an unreadable file printed a wall of red and was never counted as failed.
    # -ErrorAction Stop makes it catchable; the null check covers the rest.
    $hash = $null
    try {
        $hash = (Get-FileHash -LiteralPath $f.Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch { }
    if (-not $hash) {
        $failed++
        $failList.Add($f.Path) | Out-Null
        continue
    }

    if ($seenHash.Contains($hash)) {
        $dupes++
        # Deliberately NOT deleted, even in Move mode. The identical copy this
        # matched may have been recorded on an earlier run and since deleted from
        # the destination, in which case removing this one loses the only copy.
        # Duplicates are listed at the end for you to remove once you have verified.
        $dupeList.Add($f.Path) | Out-Null
        continue
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $ext  = [System.IO.Path]::GetExtension($f.Name)
    $target = Join-Path $Dest ($base + $ext)
    $n = 2
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $Dest ('{0}~{1}{2}' -f $base, $n, $ext)
        $n++
    }

    try {
        if ($Mode -eq 'Move') {
            Move-Item -LiteralPath $f.Path -Destination $target -Force
        } else {
            Copy-Item -LiteralPath $f.Path -Destination $target -Force
        }
        # Google Photos falls back on this when there is no EXIF date, so it has
        # to survive the transfer.
        (Get-Item -LiteralPath $target).LastWriteTime = $f.Mtime
        [void]$seenHash.Add($hash)
        [void]$doneSrc.Add($f.Path)
        Write-Row $target $f.Path $f.Bytes $f.Mtime $hash
        $writer.Flush()
        $copied++
        $copiedBytes += $f.Bytes
    } catch {
        $failed++
        $failList.Add($f.Path) | Out-Null
    }
}

$writer.Close()

Write-Host ''
Write-Host ''
Write-Host ("Gathered {0:N0} files, {1}, into {2}" -f $copied, (Format-Size $copiedBytes), $Dest)
Write-Host ("{0:N0} were exact duplicates of something already gathered, and were left where they are" -f $dupes)
if ($dupes -gt 0 -and $Mode -eq 'Move') {
    $dupeFile = Join-Path $Dest 'duplicates-left-in-place.txt'
    [System.IO.File]::WriteAllLines($dupeFile, $dupeList)
    Write-Host ("  their paths are listed in {0}, safe to delete once Google has the folder" -f $dupeFile)
}
if ($skipped) { Write-Host ("{0:N0} were already done on a previous run" -f $skipped) }
if ($failed) {
    $failFile = Join-Path $Dest 'failed.txt'
    [System.IO.File]::WriteAllLines($failFile, $failList)
    Write-Host ("{0:N0} could not be read or written; their paths are in {1}" -f $failed, $failFile)
    Write-Host '  Re-run the same command once those are readable and it will pick them up.'
}
Write-Host ("Manifest: {0}" -f $Manifest)
Write-Host ''
Write-Host 'Next:'
Write-Host ('  1. .\Collect-Photos.ps1 -Mode Dates     how many will land under the wrong date')
Write-Host ('  2. open photos.google.com and drag the folder in')
Write-Host ('  3. once Google confirms, delete the folder. The manifest says where every')
Write-Host ('     file came from, so nothing is lost track of.')

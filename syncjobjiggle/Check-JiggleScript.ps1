<#
.SYNOPSIS
    Checks the VBS the SyncJobJiggle task actually launches: does it exist, is it
    a dehydrated OneDrive placeholder, and are the paths inside it (Java in
    particular) still valid?

.DESCRIPTION
    Reads the target path straight out of the task definition rather than
    assuming it, so a stale or renamed path shows up immediately. Then:
      1. existence + OneDrive Files-On-Demand attributes + conflict copies
      2. prints the script so the logic can be reviewed
      3. extracts every hard-coded path inside it and tests each one
      4. inventories installed Java and compares against any hard-coded
         version-numbered JRE/JDK path (the classic "Java auto-updated and the
         folder name changed" breakage)
      5. optionally runs it in the foreground and reports the exit code

    Read-only unless -Run is passed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Check-JiggleScript.ps1
    powershell -ExecutionPolicy Bypass -File .\Check-JiggleScript.ps1 -Run
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'SyncJobJiggle',
    [string]$TaskPath = '\',
    [string]$ScriptPath,          # override; otherwise read from the task
    [switch]$Run
)

$ErrorActionPreference = 'Continue'
function Head($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Bad($t)  { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Good($t) { Write-Host "  [ ok ] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }

# ------------------------------------- 1. what does the task actually launch?
Head "TASK ACTION"
if (-not $ScriptPath) {
    $action = (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath).Actions |
              Select-Object -First 1
    Write-Host ("Program : {0}" -f $action.Execute)
    Write-Host ("Args    : {0}" -f $action.Arguments)
    Write-Host ("Start in: {0}" -f $(if ($action.WorkingDirectory) { $action.WorkingDirectory } else { '(empty)' }))

    # first quoted token, else the whole argument string
    if ($action.Arguments -match '"([^"]+)"') { $ScriptPath = $Matches[1] }
    else { $ScriptPath = $action.Arguments.Trim() }

    if ($action.Arguments -match '\s' -and $action.Arguments -notmatch '^\s*"') {
        Bad 'Arguments contain spaces but are NOT quoted - wscript will only see the first word.'
    }
    if (-not $action.WorkingDirectory) {
        Warn '"Start in" is empty. Any relative path inside the VBS resolves against C:\Windows\System32.'
    }
}
Write-Host ("Target  : {0}" -f $ScriptPath)

# --------------------------------------- 2. the file: exists? hydrated? moved?
Head "TARGET FILE"
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Bad "File does NOT exist at that path."
    $dir = Split-Path -Parent $ScriptPath
    if (Test-Path -LiteralPath $dir) {
        Write-Host "  Folder contents (look for a renamed / conflict copy):"
        Get-ChildItem -LiteralPath $dir -File |
            Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
    } else {
        Bad "The containing folder does not exist either: $dir"
    }
    return
}
$f = Get-Item -LiteralPath $ScriptPath -Force
Good ("Exists. {0} bytes, modified {1}" -f $f.Length, $f.LastWriteTime)

if ($ScriptPath -match 'OneDrive') {
    Warn 'Script lives under OneDrive. See the OneDrive notes at the end of this output.'
    $attr = [int]$f.Attributes
    # FILE_ATTRIBUTE_OFFLINE 0x1000 | RECALL_ON_OPEN 0x40000 | RECALL_ON_DATA_ACCESS 0x400000
    if ($attr -band 0x1000)   { Bad  'OFFLINE attribute set - file is a cloud-only placeholder.' }
    if ($attr -band 0x40000)  { Bad  'RECALL_ON_OPEN set - reading it forces a OneDrive download.' }
    if ($attr -band 0x400000) { Warn 'RECALL_ON_DATA_ACCESS set (Files On-Demand placeholder).' }
    if (-not ($attr -band 0x441000)) { Good 'File is fully hydrated locally.' }
    Write-Host ("  Attributes: {0}" -f $f.Attributes)

    $conflicts = Get-ChildItem -LiteralPath (Split-Path -Parent $ScriptPath) -File -Filter '*.vbs' |
                 Where-Object { $_.Name -ne (Split-Path -Leaf $ScriptPath) }
    if ($conflicts) {
        Warn 'Other .vbs files in the folder - check for a OneDrive conflict copy:'
        $conflicts | Select-Object Name, LastWriteTime | Format-Table -AutoSize
    }
    if (-not (Get-Process OneDrive -ErrorAction SilentlyContinue)) {
        Bad 'OneDrive.exe is NOT running. A placeholder file cannot be hydrated -> launch fails.'
    }
}
if ($f.Length -eq 0) { Bad 'File is zero bytes.' }
if ((Get-Item -LiteralPath $ScriptPath -Stream * -ErrorAction SilentlyContinue).Stream -contains 'Zone.Identifier') {
    Warn 'Mark-of-the-Web present (downloaded file). Run: Unblock-File -LiteralPath "<path>"'
}

# ------------------------------------------------------- 3. show the contents
Head "SCRIPT CONTENTS"
$text = Get-Content -LiteralPath $ScriptPath -Raw
$text -split "`r?`n" | ForEach-Object -Begin { $i = 0 } -Process { $i++; '{0,4}: {1}' -f $i, $_ }

# --------------------------------- 4. every hard-coded path inside the script
Head "HARD-CODED PATHS INSIDE THE SCRIPT"
$paths = [regex]::Matches($text, '(?<![A-Za-z0-9])([A-Za-z]:\\[^"'')\r\n]+)') |
         ForEach-Object { $_.Groups[1].Value.Trim().TrimEnd('\', ' ', '&', '_') } |
         Sort-Object -Unique
if (-not $paths) { Write-Host "  (none found - script may build paths dynamically)" }
foreach ($p in $paths) {
    if (Test-Path -LiteralPath $p) { Good $p } else { Bad "$p   <-- MISSING" }
}

# ---------------------------------------------------- 5. the Java angle
Head "JAVA"
$javaRefs = $paths | Where-Object { $_ -match 'jre|jdk|java|javaw' }
if ($text -match '(?i)java') {
    if ($javaRefs) {
        Write-Host "  Script references these Java paths:"
        foreach ($j in $javaRefs) {
            if (Test-Path -LiteralPath $j) { Good $j } else { Bad "$j   <-- MISSING (Java was likely updated)" }
        }
        if ($javaRefs -match '\d+\.\d+\.\d+') {
            Warn 'A version number is baked into the path. Every Java update renames that folder and breaks this.'
            Write-Host '       Fix: call "javaw.exe" via JAVA_HOME or PATH instead of a versioned folder, e.g.'
            Write-Host '            cmd = """" & sh.ExpandEnvironmentStrings("%JAVA_HOME%") & "\bin\javaw.exe"""'
        }
    } else {
        Write-Host "  Script mentions java but no absolute java path was found (uses PATH/JAVA_HOME - good)."
    }
} else {
    Write-Host "  Script does not reference Java at all."
}

Write-Host "  Installed / reachable Java:"
Write-Host ("    JAVA_HOME = {0}" -f $(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { '(not set)' }))
Get-Command java, javaw -All -ErrorAction SilentlyContinue |
    ForEach-Object { "    on PATH: $($_.Source)" }
foreach ($root in 'C:\Program Files\Java', 'C:\Program Files (x86)\Java',
                  'C:\Program Files\Eclipse Adoptium', 'C:\Program Files\Zulu',
                  'C:\Program Files\Amazon Corretto') {
    if (Test-Path $root) {
        Get-ChildItem $root -Directory | ForEach-Object { "    installed: $($_.FullName)" }
    }
}
$jv = & { java -version } 2>&1
if ($LASTEXITCODE -eq 0 -or $jv) { Write-Host ("    java -version: {0}" -f ($jv -join ' | ')) }

# ------------------------------------------------------------ 6. run it live
if ($Run) {
    Head "LIVE RUN (visible, so errors are readable)"
    Write-Host "  cscript //NoLogo `"$ScriptPath`""
    & cscript.exe //NoLogo $ScriptPath
    Write-Host ("  Exit code: {0}" -f $LASTEXITCODE) -ForegroundColor $(if ($LASTEXITCODE -eq 0) { 'Green' } else { 'Red' })
} else {
    Head "NEXT"
    Write-Host "  Re-run with -Run to execute the script in a visible console and see the real error."
}

Head "ONEDRIVE NOTE"
@'
  A scheduled task pointing at a script inside "OneDrive - <org>\Desktop\..." is
  fragile in three separate ways:
    * Files On-Demand can dehydrate the .vbs; wscript then blocks on a network
      hydration at launch, which is exactly what Event 111 termination and
      Event 114 missed starts look like.
    * OneDrive can rename it into a conflict copy ("run_jiggleonce-PC123.vbs"),
      leaving the task pointing at a path that no longer exists.
    * Known Folder Move can relocate Desktop entirely, changing the path.
  Move the script to a plain local folder (C:\Tools\Sync\) and repoint the task.
'@

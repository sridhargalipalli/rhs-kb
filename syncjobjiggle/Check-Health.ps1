<#
.SYNOPSIS
    One-command health check for SyncJobJiggle. Run it any time; it prints PASS,
    WARN or FAIL lines and a one-word verdict.

.DESCRIPTION
    Checks the four things that can silently break this task:
      1. the task is enabled and pointed at C:\Tools\Sync
      2. ExecutionTimeLimit is short enough that a hang self-clears
      3. the log is still being written, with no multi-hour hole
      4. no non-zero exits, stack traces, or started-but-never-finished runs

    Read-only. Safe to run at any time, elevated or not.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Check-Health.ps1
    powershell -ExecutionPolicy Bypass -File .\Check-Health.ps1 -Days 3
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'SyncJobJiggle',
    [string]$SyncDir  = 'C:\Tools\Sync',
    [int]   $Days     = 1
)

$fails = 0; $warns = 0
function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warns++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:fails++ }
function Head($m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }

# ------------------------------------------------------------- 1. the task
Head "TASK"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Fail "Task '$TaskName' not found."; return }

if ($task.State -eq 'Disabled') { Fail "Task is DISABLED." } else { Pass "State = $($task.State)" }

$act = $task.Actions | Select-Object -First 1
$cmd = "$($act.Execute) $($act.Arguments)"
if ($cmd -match [regex]::Escape($SyncDir)) { Pass "Action points at $SyncDir" }
elseif ($cmd -match 'OneDrive')            { Fail "Action still points at OneDrive: $cmd" }
else                                       { Warn "Action path unexpected: $cmd" }

$etl = $task.Settings.ExecutionTimeLimit
if ($etl -in 'PT1M','PT2M','PT3M','PT4M') { Pass "ExecutionTimeLimit = $etl (a hang self-clears)" }
elseif ($etl -eq 'PT0S')                  { Fail "ExecutionTimeLimit is unlimited - a hang blocks the task forever." }
else                                      { Warn "ExecutionTimeLimit = $etl - longer than the 5-minute interval, so a hang blocks later runs." }

if ($task.Settings.MultipleInstances -eq 'IgnoreNew') { Pass "MultipleInstances = IgnoreNew" }
else { Warn "MultipleInstances = $($task.Settings.MultipleInstances)" }

$info = Get-ScheduledTaskInfo -TaskName $TaskName
if ($info.LastTaskResult -eq 0) { Pass "LastTaskResult = 0  (last run $($info.LastRunTime))" }
else { Fail "LastTaskResult = $($info.LastTaskResult) (0x{0:X}) at $($info.LastRunTime)" -f $info.LastTaskResult }

# -------------------------------------------------------------- 2. the files
Head "FILES"
foreach ($f in 'run_jiggleonce.vbs','run_jiggleonce.bat','JiggleOnce.jar') {
    if (Test-Path "$SyncDir\$f") { Pass "$f present" } else { Fail "$f MISSING from $SyncDir" }
}
$vbs = Get-Content "$SyncDir\run_jiggleonce.vbs" -Raw -ErrorAction SilentlyContinue
if ($vbs -match ',\s*0\s*,\s*False') { Fail "VBS still uses Run(...,False) - task result will always read 0." }
elseif ($vbs -match ',\s*0\s*,\s*True') { Pass "VBS waits for completion (exit codes propagate)" }

# ---------------------------------------------------------------- 3. the log
Head "LOG  (last $Days day(s))"
$logPath = "$SyncDir\jiggle_log.txt"
if (-not (Test-Path $logPath)) { Fail "No log at $logPath"; return }

$rx = [regex]'\[Date: \w+ (\d+)/(\d+)/(\d+) Time:\s*(\d+):(\d+):(\d+)'
$lines = Get-Content $logPath
$since = (Get-Date).AddDays(-$Days)

$runs = @(); $unfinished = 0; $bad = 0
foreach ($l in $lines) {
    $m = $rx.Match($l)
    if (-not $m.Success) { continue }
    $t = New-Object DateTime ([int]$m.Groups[3].Value), ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value),
                             ([int]$m.Groups[4].Value), ([int]$m.Groups[5].Value), ([int]$m.Groups[6].Value)
    if ($t -lt $since) { continue }
    if ($l -match 'Triggered')                { $runs += $t }
    if ($l -match 'exit=(\d+)' -and $Matches[1] -ne '0') { $bad++ }
}
$starts   = ($lines | Select-String 'Starting JiggleOnce').Count
$finishes = ($lines | Select-String 'Finished JiggleOnce').Count
$traces   = ($lines | Select-String 'Exception in thread').Count

if ($runs.Count -eq 0) { Fail "No runs logged in the last $Days day(s)." }
else {
    Pass "$($runs.Count) runs logged, $($runs[0].ToString('MM/dd HH:mm')) -> $($runs[-1].ToString('MM/dd HH:mm'))"

    $age = ((Get-Date) - $runs[-1]).TotalMinutes
    if ($age -gt 15) { Warn ("Last run was {0:N0} min ago - fine if outside the 9-hour window or the PC was asleep." -f $age) }
    else             { Pass ("Last run {0:N0} min ago" -f $age) }

    # biggest hole between consecutive runs - the signature of the 08/19 hang
    $maxGap = 0; $gapAt = $null
    for ($i = 1; $i -lt $runs.Count; $i++) {
        $g = ($runs[$i] - $runs[$i-1]).TotalMinutes
        if ($g -gt $maxGap) { $maxGap = $g; $gapAt = $runs[$i-1] }
    }
    if ($maxGap -gt 60)      { Warn ("Largest gap {0:N0} min after {1:MM/dd HH:mm} - check whether the PC was asleep." -f $maxGap, $gapAt) }
    elseif ($maxGap -gt 12)  { Warn ("Largest gap {0:N0} min after {1:MM/dd HH:mm}" -f $maxGap, $gapAt) }
    else                     { Pass ("Largest gap {0:N0} min - cadence is clean" -f $maxGap) }
}

if ($bad -gt 0)    { Fail "$bad run(s) exited non-zero in the last $Days day(s)." } else { Pass "No non-zero exits" }
if ($traces -gt 0) { Warn "$traces Java stack trace(s) in the whole log (historic ones count here)." }
$unfinished = $starts - $finishes
if ($unfinished -gt 0) { Warn "$unfinished start(s) with no matching finish across the whole log - each is a run killed mid-flight." }

# ------------------------------------------------------- 4. the old location
Head "OLD ONEDRIVE COPY"
$old = "$env:USERPROFILE\OneDrive - eClinicalWorks\Desktop\Sync\jiggle_log.txt"
if (-not (Test-Path $old)) { Pass "Old folder is gone." }
elseif ((Get-Item $old).LastWriteTime -gt (Get-Date).AddHours(-2)) {
    Fail "The OneDrive log was written to recently - something is STILL running from there."
} else { Pass "Old OneDrive log is dormant (last write $((Get-Item $old).LastWriteTime))" }

# ------------------------------------------------------------------ verdict
Head "VERDICT"
if ($fails -gt 0)      { Write-Host "  UNHEALTHY - $fails failure(s), $warns warning(s)" -ForegroundColor Red }
elseif ($warns -gt 0)  { Write-Host "  OK with $warns warning(s)" -ForegroundColor Yellow }
else                   { Write-Host "  HEALTHY" -ForegroundColor Green }

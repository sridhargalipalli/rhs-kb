<#
.SYNOPSIS
    Read-only diagnostic for the SyncJobJiggle scheduled task.

.DESCRIPTION
    Pulls the task definition, its last-run result, and the Task Scheduler
    Operational-log events (111 terminated / 114 missed start / 101 launch
    failure / 201 action return codes) so the ACTUAL termination reason is
    visible instead of guessed at. Changes nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-SyncJobJiggle.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'SyncJobJiggle',
    [string]$TaskPath = '\',
    [int]   $Days     = 7,
    [string]$OutDir   = "$env:USERPROFILE\Desktop\SyncJobJiggle-diag"
)

$ErrorActionPreference = 'Stop'
$full = ($TaskPath.TrimEnd('\') + '\' + $TaskName)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Head($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------- definition
Head "TASK DEFINITION"
$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
$info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath

$task.Actions | ForEach-Object {
    Write-Host ("Action      : {0} {1}" -f $_.Execute, $_.Arguments)
    Write-Host ("WorkingDir  : {0}" -f $_.WorkingDirectory)
}
Write-Host ("RunAs       : {0}  LogonType={1}  RunLevel={2}" -f `
    $task.Principal.UserId, $task.Principal.LogonType, $task.Principal.RunLevel)
Write-Host ("State       : {0}" -f $task.State)

Head "TRIGGERS  (watch RepetitionDuration + EndBoundary)"
$task.Triggers | ForEach-Object {
    [PSCustomObject]@{
        Type              = $_.CimClass.CimClassName
        Enabled           = $_.Enabled
        StartBoundary     = $_.StartBoundary
        EndBoundary       = $_.EndBoundary
        RepeatInterval    = $_.Repetition.Interval
        RepeatDuration    = $_.Repetition.Duration      # blank/PT0S = indefinite
        StopAtDurationEnd = $_.Repetition.StopAtDurationEnd
    }
} | Format-List

Head "SETTINGS  (the usual culprits)"
$s = $task.Settings
[PSCustomObject]@{
    ExecutionTimeLimit          = $s.ExecutionTimeLimit
    MultipleInstances           = $s.MultipleInstances
    DisallowStartIfOnBatteries  = $s.DisallowStartIfOnBatteries
    StopIfGoingOnBatteries      = $s.StopIfGoingOnBatteries
    StartWhenAvailable          = $s.StartWhenAvailable
    RunOnlyIfIdle               = $s.RunOnlyIfIdle
    StopIfIdleEnd               = $s.IdleSettings.StopOnIdleEnd
    RunOnlyIfNetworkAvailable   = $s.RunOnlyIfNetworkAvailable
    WakeToRun                   = $s.WakeToRun
    Hidden                      = $s.Hidden
    RestartCount                = $s.RestartCount
    RestartInterval             = $s.RestartInterval
} | Format-List

Head "LAST RUN"
$codes = @{
    0          = 'Success'
    1          = 'Incorrect function / generic script failure'
    2          = 'File not found (check Execute path + WorkingDirectory)'
    267009     = '0x41301 Task is currently running'
    267010     = '0x41302 Task is disabled'
    267011     = '0x41303 Task has not yet run'
    267014     = '0x41306 TASK WAS TERMINATED  <-- matches Event 111'
    2147750687 = '0x8004131F An instance is already running'
    2147943645 = '0x8007045D Service not available / logon session missing'
}
$lr = $info.LastTaskResult
Write-Host ("LastRunTime : {0}" -f $info.LastRunTime)
Write-Host ("LastResult  : {0} (0x{1:X}) - {2}" -f $lr, $lr, $(if ($codes.ContainsKey([int]$lr)) { $codes[[int]$lr] } else { 'see winerror.h' }))
Write-Host ("NextRunTime : {0}" -f $info.NextRunTime)
Write-Host ("MissedRuns  : {0}" -f $info.NumberOfMissedRuns)

# -------------------------------------------------------------------- events
Head "OPERATIONAL LOG (last $Days days)"
$log = 'Microsoft-Windows-TaskScheduler/Operational'
$enabled = (Get-WinEvent -ListLog $log).IsEnabled
if (-not $enabled) {
    Write-Warning "$log is DISABLED. Enable it, then re-run after a few cycles:"
    Write-Warning "  wevtutil sl `"$log`" /e:true"
} else {
    $since = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString('s') + 'Z'
    $xml = @"
<QueryList><Query Id="0" Path="$log"><Select Path="$log">
*[System[TimeCreated[@SystemTime&gt;='$since']]]
and *[EventData[Data[@Name='TaskName']='$full']]
</Select></Query></QueryList>
"@
    $ev = @(Get-WinEvent -FilterXml $xml -ErrorAction SilentlyContinue)
    Write-Host ("Events found: {0}" -f $ev.Count)

    $ev | Group-Object Id | Sort-Object { [int]$_.Name } |
        Select-Object @{n='EventID';e={$_.Name}}, Count,
                      @{n='Meaning';e={
                          switch ([int]$_.Name) {
                              100 {'Task started'}          101 {'LAUNCH FAILURE'}
                              102 {'Task completed'}        103 {'Action start failure'}
                              111 {'TASK TERMINATED'}       114 {'Missed start'}
                              129 {'Process created'}       201 {'Action completed'}
                              203 {'Action failed to start'}329 {'Terminated: time limit'}
                              332 {'Not started: already running'}
                              default {''}
                          }}} | Format-Table -AutoSize

    Head "TERMINATION / FAILURE MESSAGES  (this is the answer)"
    $ev | Where-Object Id -in 101,103,111,114,203,329,331,332 |
        Select-Object -First 25 TimeCreated, Id, Message |
        Format-List

    Head "LAST 15 ACTION RETURN CODES (Event 201)"
    $ev | Where-Object Id -eq 201 | Select-Object -First 15 |
        ForEach-Object {
            $rc = ($_.Properties | Select-Object -Last 1).Value
            "{0}  return code {1} (0x{2:X})" -f $_.TimeCreated, $rc, [int]$rc
        }

    $ev | Select-Object TimeCreated, Id, Message |
        Export-Csv "$OutDir\taskscheduler-events.csv" -NoTypeInformation
}

# ------------------------------------------------ correlate with sleep/power
Head "POWER EVENTS (do misses line up with sleep?)"
Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = 1, 42, 107, 506, 507
        StartTime = (Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue |
    Select-Object -First 15 TimeCreated, Id,
        @{n='What';e={switch ($_.Id) {42{'Entering sleep'} 1{'Resumed'} 107{'Resumed from sleep'} 506{'Modern standby entry'} 507{'Modern standby exit'}}}} |
    Format-Table -AutoSize

Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath |
    Out-File "$OutDir\$TaskName.xml" -Encoding utf8
Write-Host ""
Write-Host "Saved task XML + event CSV to $OutDir" -ForegroundColor Green

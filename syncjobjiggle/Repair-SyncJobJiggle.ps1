<#
.SYNOPSIS
    Applies the "runs every 5 minutes, silently, forever" configuration to the
    SyncJobJiggle task without touching what the task actually executes.

.DESCRIPTION
    Fixes the five settings that cause Event 111 (terminated) and Event 114
    (missed start) on a laptop:
      * repetition duration -> indefinite (was almost certainly 1 day)
      * execution time limit -> short, so a hung run dies before the next one
      * multiple instances   -> IgnoreNew (never kill the running instance)
      * battery conditions   -> off (do not block/stop when unplugged)
      * StartWhenAvailable   -> on (catch up after sleep instead of missing)

    Backs the current definition up to XML first. Run in the SAME user context
    that owns the task, elevated if the task runs as SYSTEM or with highest
    privileges. Use -WhatIf to preview.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-SyncJobJiggle.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]  $TaskName        = 'SyncJobJiggle',
    [string]  $TaskPath        = '\',
    [TimeSpan]$Interval        = ([TimeSpan]::FromMinutes(5)),
    # Kill a run that hangs, but well before the next trigger fires.
    [TimeSpan]$ExecutionLimit  = ([TimeSpan]::FromMinutes(3)),
    [string]  $BackupDir       = "$env:USERPROFILE\Desktop\SyncJobJiggle-diag"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath |
    Out-File "$BackupDir\$TaskName.backup-$stamp.xml" -Encoding utf8
Write-Host "Backed up to $BackupDir\$TaskName.backup-$stamp.xml" -ForegroundColor Green

# ------------------------------------------------------------------ triggers
# Keep the existing trigger(s); just make the repetition endless.
$triggers = @($task.Triggers)
if ($triggers.Count -eq 0) {
    Write-Warning "No trigger found - adding an at-logon trigger."
    $triggers = @(New-ScheduledTaskTrigger -AtLogOn)
}
foreach ($t in $triggers) {
    if (-not $t.Repetition) {
        $t | Add-Member -NotePropertyName Repetition -NotePropertyValue (
            New-CimInstance -CimClass (Get-CimClass MSFT_TaskRepetitionPattern root/Microsoft/Windows/TaskScheduler) -ClientOnly
        ) -Force
    }
    $t.Repetition.Interval          = 'PT{0}M' -f [int]$Interval.TotalMinutes
    $t.Repetition.Duration          = $null    # null/absent == repeat indefinitely
    $t.Repetition.StopAtDurationEnd = $false
    $t.EndBoundary                  = $null    # never expire
    $t.Enabled                      = $true
}

# ------------------------------------------------------------------ settings
$set = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit $ExecutionLimit `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -Hidden
$set.RunOnlyIfIdle             = $false
$set.RunOnlyIfNetworkAvailable = $false
$set.Priority                  = 7          # below normal, stays out of the way

# ----------------------------------------------------------------- principal
# Interactive: required if the action touches the desktop (input/UI/session).
# Switch to -LogonType S4U only for pure background work with no UI.
$principal = New-ScheduledTaskPrincipal `
    -UserId    $task.Principal.UserId `
    -LogonType Interactive `
    -RunLevel  $task.Principal.RunLevel

if ($PSCmdlet.ShouldProcess($TaskName, 'Apply hardened 5-minute silent settings')) {
    Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath `
        -Trigger $triggers -Settings $set -Principal $principal | Out-Null
    Write-Host "Updated $TaskName." -ForegroundColor Green

    $v = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    [PSCustomObject]@{
        RepeatInterval             = $v.Triggers[0].Repetition.Interval
        RepeatDuration             = if ($v.Triggers[0].Repetition.Duration) { $v.Triggers[0].Repetition.Duration } else { 'Indefinite' }
        ExecutionTimeLimit         = $v.Settings.ExecutionTimeLimit
        MultipleInstances          = $v.Settings.MultipleInstances
        StopIfGoingOnBatteries     = $v.Settings.StopIfGoingOnBatteries
        DisallowStartIfOnBatteries = $v.Settings.DisallowStartIfOnBatteries
        StartWhenAvailable         = $v.Settings.StartWhenAvailable
        Hidden                     = $v.Settings.Hidden
    } | Format-List
}

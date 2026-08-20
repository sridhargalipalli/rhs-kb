<#
.SYNOPSIS
    XML-based repair for SyncJobJiggle. More reliable than the cmdlet route when
    a trigger was created in the GUI.

.DESCRIPTION
    Set-ScheduledTask sometimes refuses to clear a repetition <Duration> that the
    GUI wrote. This exports the task definition, edits the XML directly, and
    re-registers it, which always takes:

      * <Repetition><Duration>P1D</Duration>  -> removed (repeat indefinitely)
      * <StopAtDurationEnd>                   -> false
      * <EndBoundary>                         -> removed (never expire)
      * <MultipleInstancesPolicy>             -> IgnoreNew
      * <StartWhenAvailable>                  -> true
      * Disallow/StopIfGoingOnBatteries       -> false
      * <ExecutionTimeLimit>                  -> PT3M
      * <StopOnIdleEnd>                       -> false

    Prints a before/after diff and backs the original XML up. The action itself
    is never modified. Use -WhatIf to see the new XML without registering it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-SyncJobJiggle-Xml.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName  = 'SyncJobJiggle',
    [string]$BackupDir = "$env:USERPROFILE\Desktop\SyncJobJiggle-diag"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$xmlText = Export-ScheduledTask -TaskName $TaskName
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup  = Join-Path $BackupDir "$TaskName.backup-$stamp.xml"
$xmlText | Out-File $backup -Encoding unicode
Write-Host "Backed up to $backup" -ForegroundColor Green

[xml]$x = $xmlText
$ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
$ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

# ---------------------------------------------------------------- report first
Write-Host "`nBEFORE:" -ForegroundColor Cyan
$trigs = $x.SelectNodes('//t:Triggers/*', $ns)
Write-Host ("  Trigger count: {0}{1}" -f $trigs.Count,
    $(if ($trigs.Count -gt 1) { '   <-- more than one trigger = overlapping 5-minute series' } else { '' }))
foreach ($t in $trigs) {
    $rep = $t.SelectSingleNode('t:Repetition', $ns)
    Write-Host ("  {0}: every={1} duration={2} stopAtEnd={3} end={4}" -f $t.LocalName,
        $(if ($rep) { $rep.Interval } else { '(none)' }),
        $(if ($rep -and $rep.Duration) { $rep.Duration } else { 'indefinite' }),
        $(if ($rep) { $rep.StopAtDurationEnd } else { '-' }),
        $(if ($t.EndBoundary) { $t.EndBoundary } else { 'never' }))
}
$s = $x.SelectSingleNode('//t:Settings', $ns)
Write-Host ("  MultipleInstancesPolicy = {0}" -f $s.MultipleInstancesPolicy)
Write-Host ("  StartWhenAvailable      = {0}" -f $s.StartWhenAvailable)
Write-Host ("  ExecutionTimeLimit      = {0}" -f $s.ExecutionTimeLimit)
Write-Host ("  DisallowStartIfOnBatteries = {0}" -f $s.DisallowStartIfOnBatteries)
Write-Host ("  StopIfGoingOnBatteries     = {0}" -f $s.StopIfGoingOnBatteries)

# ------------------------------------------------------------------- edit them
foreach ($t in $trigs) {
    $rep = $t.SelectSingleNode('t:Repetition', $ns)
    if ($rep) {
        $dur = $rep.SelectSingleNode('t:Duration', $ns)
        if ($dur) { [void]$rep.RemoveChild($dur) }          # absent == indefinite
        $sad = $rep.SelectSingleNode('t:StopAtDurationEnd', $ns)
        if ($sad) { $sad.InnerText = 'false' }
    }
    $eb = $t.SelectSingleNode('t:EndBoundary', $ns)
    if ($eb) { [void]$t.RemoveChild($eb) }
}

function Set-Node($parent, $name, $value) {
    $n = $parent.SelectSingleNode("t:$name", $ns)
    if (-not $n) {
        $n = $x.CreateElement($name, 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        [void]$parent.AppendChild($n)
    }
    $n.InnerText = $value
}
Set-Node $s 'MultipleInstancesPolicy'    'IgnoreNew'
Set-Node $s 'StartWhenAvailable'         'true'
Set-Node $s 'ExecutionTimeLimit'         'PT3M'
Set-Node $s 'DisallowStartIfOnBatteries' 'false'
Set-Node $s 'StopIfGoingOnBatteries'     'false'
Set-Node $s 'Enabled'                    'true'
$idle = $s.SelectSingleNode('t:IdleSettings', $ns)
if ($idle) { Set-Node $idle 'StopOnIdleEnd' 'false' }
Set-Node $s 'RunOnlyIfIdle' 'false'

$new = $x.OuterXml
if ($PSCmdlet.ShouldProcess($TaskName, 'Re-register with repaired XML')) {
    Register-ScheduledTask -TaskName $TaskName -Xml $new -Force | Out-Null
    Write-Host "`nAFTER:" -ForegroundColor Cyan
    $v = Get-ScheduledTask -TaskName $TaskName
    foreach ($t in $v.Triggers) {
        Write-Host ("  every={0} duration={1}" -f $t.Repetition.Interval,
            $(if ($t.Repetition.Duration) { $t.Repetition.Duration } else { 'Indefinite' }))
    }
    Write-Host ("  MultipleInstances  = {0}" -f $v.Settings.MultipleInstances)
    Write-Host ("  StartWhenAvailable = {0}" -f $v.Settings.StartWhenAvailable)
    Write-Host ("  ExecutionTimeLimit = {0}" -f $v.Settings.ExecutionTimeLimit)
    Write-Host "`nDone. Now right-click the task -> Run and check jiggle_log.txt." -ForegroundColor Green
} else {
    Write-Host "`n--- proposed XML (not registered) ---`n$new"
}

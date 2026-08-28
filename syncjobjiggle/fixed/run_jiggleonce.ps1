<#
    JiggleOnce launcher with a self-enforced hard timeout.

    Replaces run_jiggleonce.bat. The batch version relied on Task Scheduler's
    ExecutionTimeLimit to rescue a wedged JVM, and on 08/28 that failed: java.exe
    ran for 40 minutes against a PT3M limit while IgnoreNew suppressed eight
    consecutive triggers (Event 322 x8). This enforces the timeout itself, so the
    behaviour no longer depends on Task Scheduler acting.

    Keeps the original log format so jiggle_log.txt stays continuous.
#>

$TimeoutSec = 60          # a healthy run takes ~2 s

$dir  = $PSScriptRoot
$log  = Join-Path $dir 'jiggle_log.txt'
$prev = Join-Path $dir 'jiggle_log.prev'

function Write-Log($msg) {
    $d = (Get-Date).ToString('ddd MM/dd/yyyy')
    $t = (Get-Date).ToString('HH:mm:ss.ff')
    Add-Content -LiteralPath $log -Value "[Date: $d Time: $t] $msg"
}

# --- rotate at 1 MB, same as the batch version ---------------------------------
if ((Test-Path $log) -and (Get-Item $log).Length -ge 1MB) {
    if (Test-Path $prev) { Remove-Item $prev -Force }
    Move-Item $log $prev -Force
}

# --- reap any JiggleOnce JVM left over from an earlier cycle -------------------
# Matched on the command line so other Java processes on the machine are untouched.
Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*JiggleOnce.jar*' } |
    ForEach-Object {
        Write-Log "Killing stale JiggleOnce JVM pid $($_.ProcessId) (started $($_.CreationDate))"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

$jar = Join-Path $dir 'JiggleOnce.jar'
if (-not (Test-Path $jar)) { Write-Log "ERROR JiggleOnce.jar not found in $dir"; exit 2 }

$javaExe = if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
    "$env:JAVA_HOME\bin\java.exe"
} else { 'java.exe' }

# LogonUI.exe is present exactly while the lock screen is up. The working theory
# for the 08/19 and 08/28 hangs is that MouseInfo.getPointerInfo() blocks rather
# than returning null on a locked desktop, so skip the cycle instead of risking
# it. Jiggling an already-locked screen achieves nothing in any case.
# If TIMEOUT lines still appear after this, the theory is wrong - equally useful.
if (Get-Process LogonUI -ErrorAction SilentlyContinue) {
    Write-Log 'Session LOCKED (LogonUI.exe present) - skipping, JVM not started'
    exit 0
}

Write-Log 'TaskScheduler Triggered after 5 mins idle'
Write-Log 'Starting JiggleOnce.jar'

$outFile = Join-Path $env:TEMP 'jiggle_out.txt'
$errFile = Join-Path $env:TEMP 'jiggle_err.txt'

$p = Start-Process -FilePath $javaExe `
        -ArgumentList '-Xms16m', '-Xmx32m', '-jar', "`"$jar`"" `
        -WorkingDirectory $dir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

# Touch .Handle before waiting. Without this, Start-Process -PassThru returns a
# Process object whose ExitCode reads back as $null once the process has exited,
# and 'exit $null' becomes 0 - which would hide every failure again.
$null = $p.Handle

if ($p.WaitForExit($TimeoutSec * 1000)) {
    $code = $p.ExitCode
    if ($null -eq $code) { $code = -1 }
} else {
    # This is the case Task Scheduler failed to handle on 08/19 and 08/28.
    try { $p.Kill() } catch { }
    $code = 1460                      # ERROR_TIMEOUT
    Write-Log "TIMEOUT after $TimeoutSec s - JVM pid $($p.Id) killed"
}

foreach ($f in $outFile, $errFile) {
    if (Test-Path $f) {
        Get-Content $f | Where-Object { $_ -ne '' } | ForEach-Object { Add-Content -LiteralPath $log -Value $_ }
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "Finished JiggleOnce.jar (exit=$code)"
Add-Content -LiteralPath $log -Value ''
exit $code

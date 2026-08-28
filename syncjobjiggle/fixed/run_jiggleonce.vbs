' Launches run_jiggleonce.ps1 with no visible window.
'
' Two deliberate choices here:
'   * the third Run() argument is True, so wscript's lifetime matches the work and
'     the real exit code reaches Task Scheduler. With False the task result was
'     pinned to 0 forever and every failure was invisible.
'   * the target is now the PowerShell launcher rather than the .bat, because it
'     enforces its own timeout on the JVM instead of trusting Task Scheduler's
'     ExecutionTimeLimit, which failed to fire on 08/19 and again on 08/28.
Option Explicit

Dim fso, sh, dir, ps1, cmd, rc
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\run_jiggleonce.ps1"

If Not fso.FileExists(ps1) Then WScript.Quit 2

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & ps1 & """"

' 0 = hidden window, True = wait for completion
rc = sh.Run(cmd, 0, True)
WScript.Quit rc

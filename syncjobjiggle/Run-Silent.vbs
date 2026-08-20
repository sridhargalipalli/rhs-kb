' Launches SyncJobJiggle with NO window at all.
' The task's "Hidden" checkbox only hides the task from the UI list - it does
' NOT stop a console window flashing when the action is a .ps1/.bat/.cmd run
' under an interactive logon. This shim does.
'
' Point the task action at:
'   Program : wscript.exe
'   Args    : "C:\Path\To\Run-Silent.vbs"
Option Explicit
Dim sh, script, cmd
script = "C:\Path\To\SyncJobJiggle.ps1"     ' <-- edit this
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """"
' 0 = hidden window, False = do not wait (set True to let the task track exit code)
sh.Run cmd, 0, True

' Launches run_jiggleonce.bat with no visible window.
'
' CHANGE FROM THE ORIGINAL: the third Run() argument is True (wait) instead of
' False (fire-and-forget).
'
' With False, wscript.exe exits within milliseconds while cmd.exe and java keep
' running. Task Scheduler logs Event 102 "task completed" almost immediately,
' then finds orphaned processes still in the task's job object and reaps them --
' which is the 102-followed-by-111 ("Task terminated") pair in the History tab.
' It also means the task's exit code is always 0 regardless of what the jar did.
'
' With True, wscript's lifetime matches the work, so 102 lands after the jar is
' genuinely done and the real exit code propagates to Task Scheduler.
Option Explicit

Dim fso, sh, batPath, rc
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

batPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\run_jiggleonce.bat"

If Not fso.FileExists(batPath) Then
    ' Surfaces as a non-zero task result instead of failing silently.
    WScript.Quit 2
End If

' 0 = hidden window, True = wait for completion
rc = sh.Run("""" & batPath & """", 0, True)
WScript.Quit rc

Set fso = CreateObject("Scripting.FileSystemObject")
batPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\run_jiggleonce.bat"
CreateObject("WScript.Shell").Run """" & batPath & """", 0, False

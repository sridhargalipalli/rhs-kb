@echo off
setlocal ENABLEDELAYEDEXPANSION
cd /d "%~dp0"

rem --- log files ---
set "LOG=%~dp0jiggle_log.txt"
set "LOG_PREV=%~dp0jiggle_log.prev"

rem --- rotate if current log >= 1 MB (1,048,576 bytes) ---
if exist "%LOG%" (
  for %%A in ("%LOG%") do set SIZE=%%~zA
  if "!SIZE!"=="" set SIZE=0
  if !SIZE! GEQ 1048576 (
    if exist "%LOG_PREV%" del /f /q "%LOG_PREV%"
    move /y "%LOG%" "%LOG_PREV%" >nul
  )
)

rem --- log task start ---
echo [Date: %date% Time: %time%] TaskScheduler Triggered after 5 mins idle >> "%LOG%"
echo [Date: %date% Time: %time%] Starting JiggleOnce.jar >> "%LOG%"

rem --- run the jar with a tiny heap and log start/end + all output ---

if exist "%JAVA_HOME%\bin\java.exe" (set "JEXE=%JAVA_HOME%\bin\java.exe") else (set "JEXE=java.exe")
"%JEXE%" -Xms16m -Xmx32m -jar "JiggleOnce.jar" >> "%LOG%" 2>&1
set "JEXIT=%ERRORLEVEL%"

rem --- log task end ---
echo [Date: %date% Time: %time%] Finished JiggleOnce.jar (exit=%JEXIT%) >> "%LOG%"
echo. >> "%LOG%"

rem --- pop up only on failure ---
if not "%JEXIT%"=="0" (
  msg "%USERNAME%" /TIME:60 "JiggleOnce failed (exit %JEXIT%) at %date% %time%. See %LOG%"
)

endlocal
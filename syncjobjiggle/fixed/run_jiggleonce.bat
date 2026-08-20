@echo off
setlocal ENABLEDELAYEDEXPANSION
cd /d "%~dp0"

rem --- log files ---
set "LOG=%~dp0jiggle_log.txt"
set "LOG_PREV=%~dp0jiggle_log.prev"

rem --- rotate if current log >= 1 MB (1,048,576 bytes) ---
if exist "%LOG%" (
  for %%A in ("%LOG%") do set "SIZE=%%~zA"
  if "!SIZE!"=="" set "SIZE=0"
  if !SIZE! GEQ 1048576 (
    if exist "%LOG_PREV%" del /f /q "%LOG_PREV%"
    move /y "%LOG%" "%LOG_PREV%" >nul
  )
)

rem --- resolve java ---
if exist "%JAVA_HOME%\bin\java.exe" (set "JEXE=%JAVA_HOME%\bin\java.exe") else (set "JEXE=java.exe")

rem --- guard: the jar must actually be here (cd above makes this the Sync folder) ---
if not exist "JiggleOnce.jar" (
  echo [Date: %date% Time: %time%] ERROR JiggleOnce.jar not found in "%~dp0" >> "%LOG%"
  endlocal & exit /b 2
)

rem --- log task start ---
echo [Date: %date% Time: %time%] TaskScheduler Triggered after 5 mins idle >> "%LOG%"
echo [Date: %date% Time: %time%] Starting JiggleOnce.jar >> "%LOG%"

rem --- run the jar with a tiny heap and log start/end + all output ---
"%JEXE%" -Xms16m -Xmx32m -jar "JiggleOnce.jar" >> "%LOG%" 2>&1
set "JEXIT=%ERRORLEVEL%"

rem --- log task end ---
echo [Date: %date% Time: %time%] Finished JiggleOnce.jar (exit=%JEXIT%) >> "%LOG%"
echo. >> "%LOG%"

rem --- notify on failure, but never block the task ---
rem  msg.exe is absent on Home editions and its window breaks "silent" operation,
rem  so it is best-effort only and its own failure is discarded.
if not "%JEXIT%"=="0" (
  where msg.exe >nul 2>&1 && msg "%USERNAME%" /TIME:60 "JiggleOnce failed (exit %JEXIT%) at %date% %time%. See %LOG%"
)

rem --- propagate the jar's exit code to wscript, and on to Task Scheduler ---
endlocal & exit /b %JEXIT%

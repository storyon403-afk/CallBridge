@echo off
setlocal
cd /d "%~dp0"
call :checks > "%~dp0windows-check.log" 2>&1
set "result=%errorlevel%"
type "%~dp0windows-check.log"
echo.
if "%result%"=="0" (echo PASS - all checks completed.) else (echo FAIL - please share windows-check.log.)
echo This check does not open media devices. Press any key to close.
pause >nul
exit /b %result%
:checks
CallBridge.CoreChecks.exe "%~dp0callbridge_abi_probe.dll"
if errorlevel 1 exit /b 1
set "CB_TEST_CORE=%~dp0camera\callbridge_abi_probe.dll"
camera\python\python.exe -I -c "import numpy, pyvirtualcam; print('PASS Windows video dependencies import')"
if errorlevel 1 exit /b 1
camera\python\python.exe -I -m unittest discover -s camera -p "test_*.py" -v
if errorlevel 1 exit /b 1
set "CB_TEST_CAMERA_SENDER=%~dp0camera\callbridge-camera-sender.exe"
runtime\node.exe camera\check_bridge.mjs
if errorlevel 1 exit /b 1
exit /b 0

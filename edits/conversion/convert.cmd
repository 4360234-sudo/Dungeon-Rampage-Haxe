:; exec "$(dirname "$0")/convert.sh" "$@"; exit
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0convert.ps1" %*
exit /b %ERRORLEVEL%

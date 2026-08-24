:; exec "$(dirname "$0")/refresh.sh" "$@"; exit
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh.ps1" %*
exit /b %ERRORLEVEL%

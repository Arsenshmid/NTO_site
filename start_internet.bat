@echo off
REM =====================================================================
REM   INTERNET ACCESS via Cloudflare Tunnel
REM   Publishes local site (localhost:8080) to a public https:// URL.
REM   Free, no public IP required, encrypted (https), works behind NAT.
REM
REM   How to use:
REM     1) Start the site first:  python app.py
REM     2) Run this file (double click).
REM     3) Wait 10-20 sec - console prints a URL like:
REM        https://xxxx-yyyy-zzzz.trycloudflare.com
REM     4) Share that URL with colleagues / citizens.
REM        It stays valid while this window is open.
REM
REM   First run downloads cloudflared.exe (~50 MB, once).
REM   Windows Defender SmartScreen may ask - allow it.
REM =====================================================================
setlocal
cd /d "%~dp0"

if not exist "cloudflared.exe" (
  echo [1/2] Downloading cloudflared.exe (one time, ~50 MB)...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile 'cloudflared.exe'"
  if not exist "cloudflared.exe" (
    echo.
    echo   DOWNLOAD FAILED.
    echo   Check internet connection or allow the file in antivirus,
    echo   then run this file again.
    echo   Or download manually from:
    echo   https://github.com/cloudflare/cloudflared/releases/latest
    echo   (file cloudflared-windows-amd64.exe, rename to cloudflared.exe,
    echo   put next to this bat file)
    pause
    exit /b 1
  )
)

echo.
echo [2/2] Starting tunnel. Keep this window OPEN.
echo       Look below for YOUR PUBLIC LINK (trycloudflare.com)...
echo       Local site must run: python app.py  (port 8080)
echo.
cloudflared.exe tunnel --url http://localhost:8080 --no-autoupdate
pause

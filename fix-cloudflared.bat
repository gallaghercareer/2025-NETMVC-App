@echo off
REM Repoint the cloudflared Windows service at the real tunnel and config file.
REM
REM `cloudflared service install` registered the service with NO arguments, so it
REM launched the exe without ever running the tunnel, and Cloudflare returned 530
REM (origin unreachable) for every hostname on it.
REM
REM Must be run from an ELEVATED prompt.

echo === stopping service ===
sc stop cloudflared
timeout /t 5 /nobreak >nul
REM cloudflared can hang in StopPending while retrying its edge connection.
taskkill /IM cloudflared.exe /F >nul 2>&1
timeout /t 2 /nobreak >nul

echo.
echo === setting command line ===
sc config cloudflared binPath= "\"C:\Program Files (x86)\cloudflared\cloudflared.exe\" --config \"C:\Users\John\.cloudflared\config.yml\" tunnel run 75479627-7b42-4bc2-b0ac-ef1924b8f817" start= auto

echo.
echo === setting failure recovery ===
sc failure cloudflared reset= 86400 actions= restart/5000/restart/10000/restart/30000

echo.
echo === starting service ===
sc start cloudflared

echo.
echo === resulting config (BINARY_PATH_NAME should contain --config and tunnel run) ===
sc qc cloudflared

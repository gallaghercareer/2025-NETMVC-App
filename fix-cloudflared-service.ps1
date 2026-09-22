#Requires -RunAsAdministrator
# Repair the cloudflared Windows service.
#
# `cloudflared service install` registered the service with NO arguments, so it
# started the exe without ever running the tunnel -> Cloudflare returned 530
# (origin unreachable) for every hostname. It also runs as LocalSystem, which looks
# for config in C:\Windows\System32\config\systemprofile\.cloudflared\, not in
# John's profile. Fix: point the service explicitly at the real config file.

$ErrorActionPreference = 'Stop'

$Exe    = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$Config = 'C:\Users\John\.cloudflared\config.yml'
$Tunnel = '75479627-7b42-4bc2-b0ac-ef1924b8f817'

if (-not (Test-Path $Exe))    { throw "cloudflared.exe not found at $Exe" }
if (-not (Test-Path $Config)) { throw "config.yml not found at $Config" }

Write-Host "`n=== 1. Validate config ===" -ForegroundColor Cyan
& $Exe tunnel --config $Config ingress validate
if ($LASTEXITCODE -ne 0) { throw "config failed validation - not touching the service" }

Write-Host "`n=== 2. Stop service ===" -ForegroundColor Cyan
Stop-Service cloudflared -Force -ErrorAction SilentlyContinue
try {
    (Get-Service cloudflared).WaitForStatus('Stopped','00:00:20')
    Write-Host "  stopped"
} catch {
    # cloudflared can hang in StopPending while retrying its edge connection and
    # never acknowledges the SCM stop. Kill the worker directly.
    Write-Host "  still StopPending after 20s - killing the process" -ForegroundColor Yellow
    # NB: not $pid - that is a read-only PowerShell automatic variable.
    $svcPid = (Get-CimInstance Win32_Service -Filter "Name='cloudflared'").ProcessId
    if ($svcPid -and $svcPid -ne 0) { Stop-Process -Id $svcPid -Force -ErrorAction SilentlyContinue }
    Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $state = (Get-Service cloudflared).Status
    if ($state -ne 'Stopped') { throw "service still $state after killing the process - reboot and retry" }
    Write-Host "  stopped (forced)"
}

Write-Host "`n=== 3. Set service command line ===" -ForegroundColor Cyan
$binPath = "`"$Exe`" --config `"$Config`" tunnel run $Tunnel"
# Set-Service, not sc.exe: sc.exe wants `binPath= <value>` as a single token and
# PowerShell splits it into two arguments, which fails with 1639 (invalid command
# line). Set-Service takes the value directly.
Set-Service -Name cloudflared -BinaryPathName $binPath -StartupType Automatic
$applied = (Get-CimInstance Win32_Service -Filter "Name='cloudflared'").PathName
if ($applied -ne $binPath) { throw "binPath did not apply. Got: $applied" }
Write-Host "  $applied"

Write-Host "`n=== 4. Restart, then recover on failure ===" -ForegroundColor Cyan
# Same sc.exe quoting trap as above - invoke through cmd so it parses the
# `key= value` pairs itself. Non-fatal: recovery settings are a nicety.
& cmd.exe /c 'sc failure cloudflared reset= 86400 actions= restart/5000/restart/10000/restart/30000' | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  (could not set failure recovery - continuing)" -ForegroundColor Yellow }
Start-Service cloudflared
(Get-Service cloudflared).WaitForStatus('Running','00:00:30')
Write-Host "  running"

Write-Host "`n=== 5. Verify ===" -ForegroundColor Cyan
Write-Host "  waiting for the tunnel to register with Cloudflare..."
Start-Sleep -Seconds 12
foreach ($u in @('https://bugtracker.gallaghercareer.com/Account/Login',
                 'https://api.gallaghercareer.com/')) {
    try   { $code = (Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 45).StatusCode }
    catch { $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode }
                    else { 'ERR ' + $_.Exception.Message } }
    Write-Host ("  {0,-56} {1}" -f $u, $code)
}
Write-Host "`n  200 = working.  530 = tunnel still not connected.  502 = tunnel up, IIS down." -ForegroundColor Green

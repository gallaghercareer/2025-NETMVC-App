#Requires -RunAsAdministrator
# Bugtracker - IIS site setup (step 5 of DEPLOY-TODO.md)
# Creates app pool + site on port 5080, sets least-privilege filesystem
# and SQL permissions, and verifies the site responds. Safe to re-run.

$ErrorActionPreference = 'Stop'

$SiteName   = 'Bugtracker'
$PoolName   = 'Bugtracker'
$AppPath    = 'C:\GitHub\2025-NETMVC-App'
$Port       = 5080
$SqlInstance= '.\MSSQLSERVER02'
$Database   = 'FinalProReRe'
$PoolIdent  = "IIS AppPool\$PoolName"

Import-Module WebAdministration

Write-Host "`n=== 1. App pool ===" -ForegroundColor Cyan
if (Test-Path "IIS:\AppPools\$PoolName") {
    Write-Host "  exists, reusing"
} else {
    New-WebAppPool -Name $PoolName | Out-Null
    Write-Host "  created"
}
Set-ItemProperty "IIS:\AppPools\$PoolName" managedRuntimeVersion 'v4.0'
Set-ItemProperty "IIS:\AppPools\$PoolName" managedPipelineMode   'Integrated'
Set-ItemProperty "IIS:\AppPools\$PoolName" processModel.identityType 'ApplicationPoolIdentity'
# Keep it warm: no idle shutdown, no daily recycle, start with IIS.
Set-ItemProperty "IIS:\AppPools\$PoolName" processModel.idleTimeout ([TimeSpan]::Zero)
Set-ItemProperty "IIS:\AppPools\$PoolName" recycling.periodicRestart.time ([TimeSpan]::Zero)
Set-ItemProperty "IIS:\AppPools\$PoolName" startMode 'AlwaysRunning'
Set-ItemProperty "IIS:\AppPools\$PoolName" autoStart $true
Write-Host "  v4.0 / Integrated / ApplicationPoolIdentity / AlwaysRunning, no idle timeout"

Write-Host "`n=== 2. Site ===" -ForegroundColor Cyan
if (Test-Path "IIS:\Sites\$SiteName") {
    Write-Host "  exists, reusing"
} else {
    New-Website -Name $SiteName -PhysicalPath $AppPath -Port $Port -ApplicationPool $PoolName | Out-Null
    Write-Host "  created on port $Port"
}
Set-ItemProperty "IIS:\Sites\$SiteName" applicationPool $PoolName
Set-ItemProperty "IIS:\Sites\$SiteName" physicalPath    $AppPath
Set-ItemProperty "IIS:\Sites\$SiteName" serverAutoStart $true

Write-Host "`n=== 3. Filesystem (read-only) ===" -ForegroundColor Cyan
# Read+execute on the app tree only. The app does not write to disk.
icacls $AppPath /grant "${PoolIdent}:(OI)(CI)(RX)" /T /C /Q | Out-Null
Write-Host "  $PoolIdent granted ReadAndExecute on $AppPath"

Write-Host "`n=== 4. SQL login (least privilege) ===" -ForegroundColor Cyan
# datareader + datawriter on this database ONLY - deliberately not db_owner.
# Migrations are run by hand from an admin context, so the app never needs DDL.
$sql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$PoolIdent')
    CREATE LOGIN [$PoolIdent] FROM WINDOWS;
USE [$Database];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$PoolIdent')
    CREATE USER [$PoolIdent] FOR LOGIN [$PoolIdent];
ALTER ROLE db_datareader ADD MEMBER [$PoolIdent];
ALTER ROLE db_datawriter ADD MEMBER [$PoolIdent];
"@
sqlcmd -S $SqlInstance -E -b -Q $sql
if ($LASTEXITCODE -ne 0) { throw "SQL grant failed" }
Write-Host "  $PoolIdent -> db_datareader + db_datawriter on $Database"

Write-Host "`n=== 5. Start + verify ===" -ForegroundColor Cyan
Start-WebAppPool -Name $PoolName -ErrorAction SilentlyContinue
Start-Website   -Name $SiteName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$r = Invoke-WebRequest "http://localhost:$Port/" -MaximumRedirection 0 -UseBasicParsing -ErrorAction SilentlyContinue
$code = if ($r) { $r.StatusCode } else { $Error[0].Exception.Response.StatusCode.value__ }
Write-Host "  GET /  -> $code  (302 to /Account/Login is CORRECT - the app requires auth)"

$a = try { Invoke-WebRequest "http://localhost:$Port/api/tickets" -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop }
     catch { $_.Exception.Response }
$acode = if ($a.StatusCode) { [int]$a.StatusCode } else { 0 }
Write-Host "  GET /api/tickets (anon) -> $acode  (401 or 302 = locked down; 200 = PROBLEM)"

Write-Host "`nDone. Open http://localhost:$Port/ and log in as admin@hiring.com" -ForegroundColor Green

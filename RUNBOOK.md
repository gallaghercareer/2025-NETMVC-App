# Bugtracker — how the deployment works

How the live site runs, what to check when it breaks, and what to do after a
reboot or a rebuild. Written 2026-09-21, when it first went live.

- **Live URL:** https://bugtracker.gallaghercareer.com
- **Local URL:** http://localhost:5080
- **Source:** `C:\GitHub\2025-NETMVC-App` — IIS serves this folder *directly*,
  there is no publish step and no copy of the app anywhere else.

For the blow-by-blow of how it got set up, and the decisions behind it, see
`DEPLOY-TODO.md`. For the demo accounts and how to rotate their passwords, see
`ReadMe.txt`. This file is just the operating picture.

---

## The request path

```
browser
  │  https://bugtracker.gallaghercareer.com
  ▼
Cloudflare edge            TLS terminates HERE. Forwards plain HTTP onward.
  │                        DNS is a CNAME to the tunnel, not to an IP.
  ▼
cloudflared  (Windows service, Automatic)
  │                        Dials OUT to Cloudflare, so no router port is
  │                        forwarded and no firewall port is open.
  │                        Config: C:\Users\John\.cloudflared\config.yml
  │                        Tunnel: 75479627-7b42-4bc2-b0ac-ef1924b8f817
  ▼
http://localhost:5080
  │
  ▼
IIS  =  W3SVC service (Automatic)  ->  WAS (Manual, pulled up by W3SVC)
  │                        W3SVC depends on WAS, so WAS starting Manual is
  │                        correct and not a misconfiguration.
  ▼
App pool "Bugtracker"  ->  w3wp.exe          <- the app actually runs here
  │                        Identity: ApplicationPoolIdentity
  │                        (virtual account "IIS AppPool\Bugtracker")
  ▼
SQL Server .\MSSQLSERVER02, catalog FinalProReRe
```

**The app is not its own Windows service.** It runs as `w3wp.exe`, a worker
process IIS spawns from the app pool. It inherits its durability from IIS rather
than being registered separately — that is the normal hosting model for ASP.NET
on Windows, and it is why this moved off IIS Express (which runs as you, and dies
when Visual Studio closes).

### Everything survives a reboot

| Layer | Kind | Startup |
|---|---|---|
| `cloudflared` | Windows service | Automatic |
| `W3SVC` (IIS) | Windows service | Automatic |
| `WAS` | Windows service | Manual — started by W3SVC as a dependency |
| App pool → `w3wp.exe` | IIS worker process | `startMode=AlwaysRunning`, `autoStart=true` |
| `MSSQL$MSSQLSERVER02` | Windows service | Automatic |

No login is required. Nothing has a window to close.

The app pool also has `idleTimeout=0` and `recycling.periodicRestart.time=0`.
Both defaults (shut down after 20 min idle, recycle every 29 hours) would make an
occasional visitor pay a 5–15s cold start while .NET re-JITs and EF rebuilds its
model. Since this site's traffic is *hours of silence, then one recruiter*, that
visitor would reliably eat it. Trade-off: if the app ever leaks memory, the
recycle was hiding it — watch `w3wp.exe` memory if things get slow.

---

## Deploying a change

There is no publish step. IIS serves the source folder directly.

```powershell
# from C:\GitHub\2025-NETMVC-App
& 'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe' FinalProReRe.sln /p:Configuration=Debug
```

- **C# changes** (controllers, models) — rebuild. Writing `bin\FinalProReRe.dll`
  makes ASP.NET recycle the app automatically; no IIS restart needed.
- **View changes** (`.cshtml`) — no rebuild at all. Razor compiles at runtime, so
  saving the file is enough. Just reload the page.
- **`Web.config` changes** — saving it restarts the app on its own.

If something seems stale: `iisreset` (elevated) is the blunt instrument.

---

## Database

- **Instance:** `.\MSSQLSERVER02` (SQL Server 2025, Standard **Developer**
  Edition), catalog `FinalProReRe`.
- **Connection string:** `Web.config` line 12, Integrated Security.
- **The app pool identity** `IIS AppPool\Bugtracker` has `db_datareader` +
  `db_datawriter` on this database **only** — deliberately not `db_owner`. The app
  never does DDL at runtime, and this instance also hosts `HealthApp`, so a
  compromise of the web app cannot reach it.

Migrations are EF6 and are run **by hand**, from an admin context — never by the
app. There is no `dotnet ef`; use the CLI that ships in `packages`:

```powershell
packages\EntityFramework.6.4.4\tools\net45\any\ef6.exe database update `
  --assembly bin\FinalProReRe.dll --config Web.config
```

Build first — `ef6.exe` reads the compiled assembly, not the source, so a
connection-string change needs a rebuild before it takes effect.

**Any fresh database re-seeds password hashes that are public in git history.**
Rotate them immediately after `database update`. Procedure is in `ReadMe.txt`.

**There are no backups.** SQL Agent is stopped on every instance on this box.

---

## Rebuilding the hosting from scratch

Two scripts at the repo root, both **must be run elevated**:

- **`setup-iis.ps1`** — creates the app pool and site, sets the keep-warm
  settings, grants read-only NTFS to the pool identity and the SQL login, then
  verifies. Idempotent; safe to re-run.
- **`fix-cloudflared.bat`** — repairs the cloudflared service registration (see
  the gotcha below). Also idempotent.

If IIS itself is gone, install it first:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-ASPNET45,IIS-NetFxExtensibility45,IIS-ISAPIExtensions,IIS-ISAPIFilter,IIS-ManagementConsole -All
```

---

## When it breaks

Work **down** the stack — the error code tells you how far the request got.

| Symptom | Where it broke | Do this |
|---|---|---|
| **530** from Cloudflare | cloudflared is not connected to the edge | `Get-Service cloudflared`. Check `binPath` (see gotcha 1). |
| **502 / 504** | tunnel is up, IIS is not answering | Is `w3wp.exe` running? Does `http://localhost:5080` work locally? |
| **Works local, fails public** | tunnel or DNS | `cloudflared tunnel ingress validate`, then `nslookup bugtracker.gallaghercareer.com` |
| **Login redirect loop** | cookie is being refused | `CookieSecure` must stay `SameAsRequest` — see below |
| **Yellow ASP.NET error page** | the app itself | `customErrors` is `RemoteOnly`, so browse from the box to see the real error |
| **Ticket table empty but page loads** | the AJAX call to `/api/tickets` failed | Open devtools Network. The table is filled client-side, not server-rendered. |
| **Site slow on first hit** | app pool cold start | Check `idleTimeout`/`startMode` are still 0 / AlwaysRunning |

Quick health check, no elevation needed:

```powershell
Get-Service cloudflared,W3SVC | Format-Table Name,Status,StartType
Get-Process w3wp,cloudflared -ErrorAction SilentlyContinue | Format-Table Name,Id
Invoke-WebRequest http://localhost:5080/Account/Login -UseBasicParsing | Select-Object StatusCode
```

---

## Things that look broken but are not

**`CookieSecure = SameAsRequest` in `App_Start\Startup.Auth.cs` is deliberate.**
Do not "fix" it to `Always`. Cloudflare terminates TLS and forwards **plain
HTTP** to localhost, so `Always` would see a non-HTTPS request, refuse to set the
auth cookie, and produce an infinite login redirect. HTTPS is forced at the
Cloudflare edge instead ("Always Use HTTPS"), so the browser never sends the
cookie in the clear. Also note `CookieSameSite` does not exist in
Microsoft.Owin 4.0.1 — setting it is a compile error.

**Cloudflare SSL/TLS mode must be Full or Flexible, not Strict.** Strict expects a
certificate on the origin; there isn't one, because the tunnel speaks plain HTTP
to localhost.

**`WAS` startup type is Manual.** Correct — `W3SVC` depends on it and starts it.

**`https://api.gallaghercareer.com/` returns 404.** That is the *other* app on
port 5018 answering for `/`. The tunnel is fine.

**`Views/_ViewStart.cshtml` sets `Layout = null`.** Every ticket view is a
standalone HTML document. `_Layout.cshtml` is effectively dead.

**Manager and employee pages are separate files with duplicated markup**
(`EmployeeIndex` / `LimitedEmployeeIndex`, `ViewTicket` / `EmployeeViewTicket`).
A UI change usually has to be made twice.

---

## Two gotchas that cost real time

**1. `cloudflared service install` registers the service with NO arguments.**
It sets `binPath` to the bare exe, so the service starts but never runs the
tunnel, and *every* hostname on it returns 530 — including ones that worked
before. It also runs as LocalSystem, which looks for config under
`System32\config\systemprofile\.cloudflared\`, not in your user profile. The
binPath must be:

```
"C:\Program Files (x86)\cloudflared\cloudflared.exe" --config "C:\Users\John\.cloudflared\config.yml" tunnel run 75479627-7b42-4bc2-b0ac-ef1924b8f817
```

Fix with `fix-cloudflared.bat`. It is a **batch file on purpose**: `sc.exe` wants
`binPath= <value>` as one token and PowerShell splits it (error 1639), while
`Set-Service -BinaryPathName` needs PowerShell 7+ and this box runs 5.1. Also,
`sc stop` often fails with 1061 because cloudflared hangs in StopPending while
retrying its edge connection — `taskkill /F` is the reliable stop.

**2. Cloudflare Email Obfuscation rewrites the demo credentials.** Scrape Shield
turns anything that looks like an email into a `/cdn-cgi/l/email-protection`
link, so the login page shows `[email protected]` instead of the username a
visitor needs to type. The passwords render fine, which makes it look like an
application bug. Turn it off at: dash.cloudflare.com → gallaghercareer.com →
Scrape Shield → Email Address Obfuscation.

---

## Known and accepted

- **`ViewTicket` writes on GET with no antiforgery token** — CSRF, reviewed and
  declined 2026-09-21. No real data, worst case is spam comments. Details in
  `DEPLOY-TODO.md`.
- **MSSQLSERVER02 is Developer Edition**, which is not licensed for production
  use, and a public site is production use. Accepted; moving to `.\SQLEXPRESS`
  (2019 Express, production-licensed) is a connection-string change plus a
  migration re-run plus a password rotation.
- **No backups** anywhere on this box.
- **Self-registration is disabled** in `AccountController` — the commented-out
  block granted `CanManageTickets` to every new signup. Do not re-enable as-is.
  Visitors use the published demo accounts.
- **The GitHub Actions workflow** `.github/workflows/master_bugtracker.yml` still
  deploys to the removed Azure App Service on every push to `master`, and fails.

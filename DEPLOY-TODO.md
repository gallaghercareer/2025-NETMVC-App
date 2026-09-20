# Deployment TODO — expose Bugtracker via Cloudflare Tunnel

**Goal:** get this app running locally on IIS + SQL Server Express, exposed publicly
through the existing Cloudflare tunnel as a portfolio piece.

**Audience decision:** public. Anyone on the internet can reach the login page, so the
security work below is a prerequisite, not optional hardening.

Status as of 2026-09-17.

---

## Context you'll want when you come back

- **Stack:** ASP.NET MVC 5 on .NET Framework 4.7.2. Not .NET Core. Needs IIS —
  it cannot run on Kestrel, there is no self-host path.
- **Auth:** ASP.NET Identity (not Entra ID). This was checked and is fine for public
  exposure: PBKDF2 hashes, OWIN security stamp revalidated every 30 min, lockout after
  5 failed attempts. Entra ID would add SSO/MFA/central account management but is an
  improvement, not a blocker — treat as a possible follow-up, not part of this work.
- **Why it left Azure:** App Service + SQL database cost. Replacement is local
  SQL Server Express (already installed) + Cloudflare tunnel (already configured).
- **Machine state found on 2026-09-17:**
  - SQL Server: 5 instances installed, 4 running (`MSSQLSERVER`, `SQLEXPRESS`,
    `MSSQLSERVER01`, `MSSQLSERVER02`; `SQLEXPRESS01` stopped).
  - `cloudflared`: installed at `C:\Program Files (x86)\cloudflared\cloudflared.exe`,
    tunnel `75479627-7b42-4bc2-b0ac-ef1924b8f817` configured for
    `api.gallaghercareer.com` -> `http://localhost:5018` (a different app).
    **No Windows service registered** — the tunnel only runs while started manually.
  - **IIS: not installed.** No `W3SVC`, no `appcmd.exe`. This is the main blocker.
  - MSBuild: `C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe`
  - `nuget.exe` is not on PATH (packages are already restored in `packages/`, so
    builds work without it).

---

## DONE — security fixes (committed to working tree, builds clean)

Verified with a successful Debug build on 2026-09-17.

- [x] **`/api/tickets` was fully anonymous** — no `[Authorize]` anywhere, exposing
      read/create/update/delete to the internet. Added `[Authorize]` on the controller
      and `[Authorize(Roles = "CanManageTickets")]` on POST/PUT/DELETE.
      `Controllers/Api/TicketsController.cs:11,53,67,93`
- [x] API controller never disposed its `ApplicationDbContext`. Added `Dispose`
      override. `Controllers/Api/TicketsController.cs:22`
- [x] **Privilege escalation:** `ViewTicket` flipped `Resolved` without re-checking the
      role, so a `CanViewTicketsOnly` user could resolve tickets by editing the URL.
      Now gated on `User.IsInRole("CanManageTickets")`. `Controllers/HomeController.cs:113`
- [x] `customErrors mode="Off"` leaked full stack traces. Now `RemoteOnly`. `Web.config`
- [x] **Glimpse removed** from `Web.config` (was `defaultRuntimePolicy="On"` with the
      security policy commented out — `/glimpse.axd` would have exposed SQL queries,
      connection details and server variables to anyone). Assemblies are still
      referenced but no handler is registered, so they're harmless dead weight.
- [x] Added security headers (`X-Content-Type-Options`, `X-Frame-Options`,
      `Referrer-Policy`), removed `X-Powered-By`, set `httpOnlyCookies`. `Web.config`
- [x] Auth cookie: `CookieHttpOnly`, 8h sliding expiry. `App_Start/Startup.Auth.cs`
- [x] Removed live admin/employee passwords from `ReadMe.txt`.

### Note on `CookieSecure` — don't "fix" this

`App_Start/Startup.Auth.cs` uses `CookieSecureOption.SameAsRequest`, **not** `Always`.
This is deliberate. Cloudflare terminates TLS and forwards **plain HTTP** to localhost,
so `Always` would see a non-HTTPS request, refuse to set the cookie, and produce an
infinite login redirect. Force HTTPS at the Cloudflare edge instead, so the browser
never sends the cookie in the clear.

Also: `CookieSameSite` does **not** exist in Microsoft.Owin 4.0.1 (the version pinned
here). Setting it is a compile error — it was tried and reverted.

---

## TODO — remaining work

### 1. Install IIS  ← the blocker
Needs an **elevated** PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-ASPNET45,IIS-NetFxExtensibility45,IIS-ISAPIExtensions,IIS-ISAPIFilter -All
```

If ASP.NET 4.x doesn't register with IIS afterwards:

```powershell
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe -i
```

### 2. Point the connection string at SQL Express
`Web.config` line ~12 currently reads `(LocalDb)\mssqllocaldb`. **LocalDB is
developer-only and user-session-scoped — it will not run under an IIS app pool.**
Change to:

```xml
<add name="DefaultConnection"
     connectionString="Data Source=.\SQLEXPRESS;Initial Catalog=FinalProReRe;Integrated Security=True"
     providerName="System.Data.SqlClient" />
```

(`SQLEXPRESS` suggested over the default instance to keep this app isolated from
whatever else is on the box. Any running instance works.)

### 3. Create the database
From the Visual Studio **Package Manager Console** (EF6 migrations, not `dotnet ef`):

```powershell
Update-Database
```

Runs the 15 migrations in `Migrations/`. `AutomaticMigrationsEnabled = false`, so
schema changes always need an explicit `Add-Migration`.

### 4. Rotate the seeded accounts  ← CANNOT BE SKIPPED
Migration `202010021455391_canmanageticketrole.cs` seeds two accounts with
**hardcoded password hashes**, and the plaintext passwords were committed in
`ReadMe.txt`. They are in git history and cannot be un-published. Step 3 recreates
those accounts on the new database.

- `admin@hiring.com` — role `CanManageTickets`
- `employee@hiring.com` — role `CanViewTicketsOnly`

Both passwords must be changed **after** `Update-Database` and **before** the tunnel
opens. Otherwise anyone who reads the repo has admin on the public site.

### 5. IIS site + app pool, verify locally
- App pool: **.NET CLR v4.0**, Integrated pipeline.
- Point the site at `C:\GitHub\2025-NETMVC-App` on a spare local port (not 5018 —
  that's taken by the other app).
- Grant the app pool identity (`IIS AppPool\<name>`) read access to the folder, and
  a SQL login with `db_owner` on `FinalProReRe`.
- Verify on `http://localhost:<port>` before touching the tunnel: log in as admin,
  confirm the ticket table populates (it loads via AJAX from `/api/tickets` — if the
  table is empty, that call is failing), and confirm `/api/tickets` returns 401 in a
  logged-out private window.

### 6. Tunnel
Add a second ingress to `C:\Users\John\.cloudflared\config.yml`, **above** the
catch-all 404 (order matters — first match wins):

```yaml
ingress:
  - hostname: api.gallaghercareer.com
    service: http://localhost:5018
  - hostname: <new-hostname>.gallaghercareer.com
    service: http://localhost:<iis-port>
  - service: http_status:404
```

Then add the DNS route and install the service so the tunnel survives reboot:

```powershell
cloudflared tunnel route dns 75479627-7b42-4bc2-b0ac-ef1924b8f817 <new-hostname>.gallaghercareer.com
cloudflared service install   # elevated
```

Force HTTPS at the Cloudflare edge (Always Use HTTPS) — see the `CookieSecure` note.

### 7. Final check before announcing it
- [ ] `/api/tickets` returns 401 when logged out
- [ ] Seeded passwords rotated (step 4)
- [ ] `/glimpse.axd` returns 404
- [ ] An error page shows no stack trace
- [ ] Employee account cannot resolve a ticket by editing the URL

---

## Known issues, deliberately deferred

- **`ViewTicket` mutates state over GET with no antiforgery token.** Resolving is now
  role-checked, but any logged-in user can still be CSRF'd into posting a comment.
  Fixing it properly means reworking the action into a POST and updating both
  `ViewTicket.cshtml` and `EmployeeViewTicket.cshtml`. Real, but low severity —
  shouldn't block launch.
- **Self-registration is commented out** in `AccountController` (the disabled block
  granted `CanManageTickets` to every new signup — do not re-enable as-is). Public
  visitors therefore cannot create accounts; they need the demo credentials. Decide
  how a recruiter is meant to get in: a read-only demo account with a rotated
  password is probably the answer.
- **Glimpse packages** are still in `packages.config` and referenced by the csproj.
  Harmless now, but could be removed for cleanliness.
- The GitHub Actions workflow `.github/workflows/master_bugtracker.yml` still deploys
  to the (now removed) Azure App Service on every push to `master`. It will fail.
  Disable or delete it.

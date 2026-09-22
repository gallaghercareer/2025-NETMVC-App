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

### 2. Point the connection string at SQL Server — DONE 2026-09-20
`Web.config` line 12 now reads:

```xml
<add name="DefaultConnection"
     connectionString="Data Source=.\MSSQLSERVER02;Initial Catalog=FinalProReRe;Integrated Security=True"
     providerName="System.Data.SqlClient" />
```

**Instance: `.\MSSQLSERVER02`** (SQL Server 2025, Standard Developer Edition).
Chosen by John on 2026-09-20 to consolidate with his other projects. It was briefly
set up on `.\SQLEXPRESS` first; that database has been dropped.

The five instances on this box, checked 2026-09-20:

| Instance | Version / edition | Service |
|---|---|---|
| `.\SQLEXPRESS` | 2019 **Express** | Running/Automatic |
| `.\MSSQLSERVER01` | 2022 Developer | Running/Automatic |
| `.\MSSQLSERVER02` | 2025 Developer | Running/Automatic |
| `.` (default) | 2022 Developer | Running/Automatic |
| `.\SQLEXPRESS01` | — | Stopped/Manual |

All the running instances are Automatic, so any of them survives a reboot.

**Open licensing question — decide before announcing the site.** Developer Edition
is free but licensed for development and test use only, not production. Exposing
this app publicly is production use, and `SQLEXPRESS` (2019 Express) is the only
production-licensed instance here. Moving back is cheap: change the connection
string, re-run the migrations, re-rotate the passwords (step 4). Note that a
separate Cloudflare tunnel does **not** change this — a tunnel is still public
exposure. Putting Cloudflare Access in front of the hostname would genuinely make
it private, and would settle the question.

**Do not point this app at `MSSQLSERVER01.BugTracker` despite the name** — that
database has an `__EFMigrationsHistory` table (EF *Core*) and no `AspNetUsers`, so
it belongs to a different project entirely. This app's EF6 history table is
`__MigrationHistory`.

Also noted: `SQLBrowser` is disabled and SQL Agent is stopped on every instance.
Neither matters for a same-box named-instance connection, but it means **there are
no scheduled backups anywhere**. Worth setting up once this is public.

### 3. Create the database — DONE 2026-09-20
Did **not** need the Package Manager Console. EF 6.4 ships a CLI at
`packages/EntityFramework.6.4.4/tools/net45/any/ef6.exe`, which does the same job:

```powershell
packages\EntityFramework.6.4.4\tools\net45\any\ef6.exe database update `
  --assembly bin\FinalProReRe.dll --config Web.config
```

Build first — `ef6.exe` reads the compiled assembly, not the source (so a connection
string change needs a rebuild before it takes effect). 13 migrations applied against
`.\MSSQLSERVER02`, catalog `FinalProReRe`, Seed method ran, both accounts and both
roles present, `Tickets` empty. No compatibility problems running this EF6 / .NET
Framework 4.7.2 stack against the 2025 engine (default compatibility level 170).
`AutomaticMigrationsEnabled = false`, so schema changes still need `Add-Migration`.

### 4. Rotate the seeded accounts — DONE 2026-09-20
Migration `202010021455391_canmanageticketrole.cs` seeds two accounts with
**hardcoded password hashes**, and the plaintext passwords were committed in
`ReadMe.txt`. They are in git history and cannot be un-published. Step 3 recreates
those accounts on the new database.

- `admin@hiring.com` — role `CanManageTickets`
- `employee@hiring.com` — role `CanViewTicketsOnly`

Both were rotated on 2026-09-20, directly after `Update-Database` — and again after
the database was recreated on `.\MSSQLSERVER02`, which re-seeded the public hashes. New hashes were
generated with `Microsoft.AspNet.Identity.PasswordHasher` (so the format matches what
the login path expects) and `SecurityStamp` was rotated at the same time, which
invalidates any auth cookie issued against the old credentials. Verified: neither
stored hash matches the value in the migration file any more.

The new passwords are not in the repo — they were handed over in the session that set
them. **If they were not saved anywhere, rotate again** using the procedure in
`ReadMe.txt`; there is no password-reset email flow configured to recover an account.

Note this has to be redone for every fresh database: `Update-Database` re-seeds the
public hashes from the migration.

### 5. IIS site + app pool — DONE 2026-09-20

IIS installed (`RestartNeeded: False`), `W3SVC` running and AUTO_START. Site and
pool created by **`setup-iis.ps1`** (committed at the repo root, idempotent, must be
run elevated). Verified live on `http://localhost:5080`:

- `GET /` -> 302 to login (HomeController is `[Authorize]`)
- `GET /api/tickets` anonymous -> 302 (the `[Authorize]` fix holds)
- demo login as `employee@hiring.com` -> 302 + auth cookie issued
- `GET /api/tickets` authenticated -> 200

### 5b. Original step 5 notes (kept for reference)

Note the distinction: **IIS Express** (what F5 in Visual Studio launches) runs as
your user and dies when VS closes. **Full IIS** is the `W3SVC` Windows service —
starts at boot before login, survives logoff, nothing to accidentally close. That
durability is the whole reason for this step.

**What an app pool is** (notes from 2026-09-20 — this is the part of IIS that is
not obvious if you have only ever used F5 / IIS Express):

IIS does not run your code itself. It hands requests to a separate worker process,
`w3wp.exe`, and the app pool is the *configuration of that process* — runtime
version, identity, lifetime. One pool = one worker = one isolation boundary, so a
crash or leak in one site cannot affect another. IIS Express hides all of this: one
app, running as you, no pool.

Settings used by `setup-iis.ps1`, and why:

- **`managedRuntimeVersion v4.0`** — .NET Framework 4.7.2 runs on CLR v4.0. The CLR
  version stopped incrementing after 4.0 even though the framework went to 4.8, so
  "v4.0" is correct here, not stale.
- **`managedPipelineMode Integrated`** — required by MVC 5. The legacy "Classic"
  mode breaks routing like `/Home/ViewTicket/5`.
- **`ApplicationPoolIdentity`** — a virtual account (`IIS AppPool\Bugtracker`)
  created per pool: no password, cannot log in interactively, minimal rights. This
  is the **main security boundary**. It is the account that holds the SQL grant, so
  a compromise of the web app is confined to datareader/datawriter on
  `FinalProReRe` and cannot reach `HealthApp` or the other databases on that
  instance. Do not change this to a real account or to LocalSystem.
- **`idleTimeout = 0`** — default is 20 min, after which IIS kills the worker to
  save memory. The next request restarts it, but pays 5-15s of cold start while .NET
  re-JITs and EF rebuilds its model. This site's traffic pattern is *hours of
  silence, then one recruiter*, so that recruiter would reliably eat the cold start.
- **`recycling.periodicRestart.time = 0`** — default recycles every 29 hours
  regardless of traffic (the odd number drifts the restart around the clock). That
  default exists to paper over memory leaks. Tradeoff: if this app *does* leak, the
  recycle was hiding it. Watch memory once it is live.
- **`startMode AlwaysRunning`** + site `serverAutoStart` — start the worker when
  IIS starts rather than on first request, so a reboot does not leave the first
  visitor waiting. Caveat: this starts the *process*; ASP.NET still initializes the
  app lazily on first request. Eliminating that entirely needs the Application
  Initialization module plus a warmup URL — deliberately skipped for now, easy to
  add if first loads feel slow.

- App pool: **.NET CLR v4.0**, Integrated pipeline.
- **Set `idleTimeout` to 0 and `startMode` to `AlwaysRunning`.** By default an app
  pool idles out after 20 min and recycles every 29 hours. The site still works, but
  the first request after a quiet spell pays a multi-second cold start while .NET and
  EF warm up — i.e. exactly the request a recruiter makes. Also set the service
  `WAS`/`W3SVC` startup to Automatic (it is by default).
- Point the site at `C:\GitHub\2025-NETMVC-App` on a spare local port (not 5018 —
  that's taken by the other app).
- Grant the app pool identity (`IIS AppPool\<name>`) read access to the folder, and
  a SQL login with `db_owner` on `FinalProReRe`.
- Verify on `http://localhost:<port>` before touching the tunnel: log in as admin,
  confirm the ticket table populates (it loads via AJAX from `/api/tickets` — if the
  table is empty, that call is failing), and confirm `/api/tickets` returns 401 in a
  logged-out private window.

### 5c. Login page credentials — FIXED 2026-09-20

`Views/Account/Login.cshtml` hardcoded the **old** admin and employee passwords in
three places, and pre-filled both the email (`Admin@hiring.com`) and the password
box with `Adminpass123!` — i.e. it shipped a complete, pre-typed admin login. Those
credentials were already dead (rotated on 2026-09-20), so nothing was ever exposed,
but it had to go before launch.

Now: nothing is pre-filled, and a styled panel lists **both** demo accounts, manager
first. Passwords come from the `DemoPassword` / `DemoEmployeePassword` appSettings in
`Web.config` via ViewBag (`Controllers/AccountController.cs:63-64`) rather than being
hardcoded in the view, so rotating one is a config change, not a code change.

Both are published on purpose (decided 2026-09-21): the manager account shows the
full feature set and is the one a visitor should start with, and the employee account
exists so a visitor can log in again and *see* the RBAC restrictions rather than just
read about them. Accepted trade-off: any visitor can add and delete demo tickets.

**Keep both appSettings in sync** with the real passwords in the database; if they
drift, the login page advertises credentials that do not work.

### 6. Tunnel

**Decided 2026-09-20: `bugtracker.gallaghercareer.com` on port 5080.**

No new domain and no new tunnel are needed. Unlike the other project (static
front-end hosted separately + API on 5018), this app has **no separate front-end** —
it is server-rendered Razor, and the views fetch `/api/tickets` as a *relative*
same-origin path (`Views/Home/EmployeeIndex.cshtml:66`,
`Views/Home/LimitedEmployeeIndex.cshtml:62`). Pages and API are one IIS application
on one port, so one hostname covers the whole app.

Add a second ingress to `C:\Users\John\.cloudflared\config.yml`, **above** the
catch-all 404 (order matters — first match wins):

```yaml
ingress:
  - hostname: api.gallaghercareer.com
    service: http://localhost:5018
  - hostname: bugtracker.gallaghercareer.com
    service: http://localhost:5080
  - service: http_status:404
```

Then add the DNS route and install the service so the tunnel survives reboot.

**`cloudflared` is currently NOT a service** (checked 2026-09-20 — running as a
manually-started process, PID 32804). It dies on logoff or reboot, which means
`api.gallaghercareer.com` is already going dark whenever that happens. Installing
the service fixes this for **both** apps at once: one tunnel process serves every
hostname in the ingress list.

```powershell
cloudflared tunnel route dns 75479627-7b42-4bc2-b0ac-ef1924b8f817 bugtracker.gallaghercareer.com
cloudflared service install   # elevated
```

Force HTTPS at the Cloudflare edge (Always Use HTTPS) — see the `CookieSecure` note.

### 6b. UNDECIDED — how exposed should this be? (raised 2026-09-20)

Open question, deliberately parked. Nothing goes public until it is answered.

**What always-on IIS does and does not change.** IIS listening on 5080 is not the
same as the internet reaching it: no router port is forwarded and no firewall port is
opened (all three firewall profiles confirmed enabled). `cloudflared` dials *out* to
Cloudflare and traffic returns down that connection — the tunnel is the only door,
and only for hostnames in the ingress list.

**The real risks, in rough priority order:**

1. **Bots find it within days.** Automated scanners will probe for `/wp-admin`,
   `.env`, known CVEs, and will try credential stuffing on `/Account/Login`. This is
   ambient internet background noise, not a maybe. Partly mitigated already: 5-attempt
   lockout, PBKDF2 hashes, and the `[Authorize]` fix on `/api/tickets` (which was
   fully anonymous before — that fix matters a lot here).
2. **This box is not a DMZ.** It is John's dev machine. Other databases on it:
   `FinanceApplication`, `StackOverflow2013`, `JulioDatabase`, `SameerDatabase`,
   `HealthApp` — plus source code and credentials. `HealthApp` shares the
   `MSSQLSERVER02` instance with this app's database.
3. **The deferred CSRF hole becomes reachable.** `ViewTicket` mutates state over GET
   with no antiforgery token (see "Known issues" below). Worst case is spam comments,
   but it goes from theoretical to internet-reachable.
4. Unpatched framework surface (.NET 4.7.2 / MVC 5 — still supported, keep Windows
   Update current) and IIS default pages/version headers.

**Therefore, non-negotiable in step 5** (these tighten what a breach could reach):
- SQL login for the app pool: `db_datareader` + `db_datawriter` on `FinalProReRe`
  **only** — *not* `db_owner`, and no access to `HealthApp` or the other databases.
  The app never does DDL at runtime; migrations are run by hand from an admin context,
  so `db_owner` buys nothing and costs a lot in a breach.
- App pool runs as `ApplicationPoolIdentity` with **read-only** NTFS on the app
  folder. Never as John's account, never as an administrator.

**The options, when you come back to this:**

- **Cloudflare Access** (free) — auth at the edge, so scanners never reach the
  machine. Also neutralizes the CSRF issue and resolves the Developer Edition
  licensing question in step 2 (arguably no longer public production use). Cost:
  recruiters hit an email-code gate before they see the app.
- **Open + Cloudflare WAF and rate limiting** (both free tier; rate-limit
  `/Account/Login` specifically) — zero friction, but scanners reach the app and the
  CSRF hole is live.
- **Open, but fix the CSRF issue first** — rework `ViewTicket` into a POST with an
  antiforgery token; touches `ViewTicket.cshtml` and `EmployeeViewTicket.cshtml`.

### 6c. LIVE 2026-09-21 — and two gotchas hit on the way

`https://bugtracker.gallaghercareer.com` is reachable. Verified over the public URL:
login page 200, manager login succeeds, authenticated `/api/tickets` returns JSON,
anonymous `/api/tickets` redirects to login.

**Gotcha 1 — `cloudflared service install` registers the service with NO arguments.**
It set `binPath` to the bare exe, so the service started but never ran the tunnel,
and every hostname (including the pre-existing `api.`) returned **530 origin
unreachable**. It also runs as LocalSystem, which looks for config under
`System32\config\systemprofile\.cloudflared\` rather than John's profile. Fix is
`fix-cloudflared.bat` (repo root, run elevated), which sets the binPath to the exe
plus `--config <path to config.yml> tunnel run <tunnel id>`.

Notes for next time: a `.bat` is used deliberately because `sc.exe` wants
`binPath= <value>` as a single token and PowerShell splits it (error **1639**).
`Set-Service -BinaryPathName` would be cleaner but needs PowerShell 7+; this box
runs Windows PowerShell 5.1. `sc stop` often fails with **1061** and cloudflared
hangs in StopPending while retrying its edge connection — `taskkill /F` is the
reliable stop, and the batch file does that. Failure-recovery actions are set so the
service restarts itself if the tunnel dies.

**Gotcha 2 — Cloudflare Email Obfuscation mangles the demo credentials.** Scrape
Shield rewrites anything that looks like an email into a
`/cdn-cgi/l/email-protection` link, so the login page shows `[email protected]`
instead of the usernames a visitor needs to type. The passwords render fine, which
makes it look like a ViewBag bug. **Turn it off:** dash.cloudflare.com →
gallaghercareer.com → Scrape Shield → Email Address Obfuscation → Off.

**Unrelated:** `https://api.gallaghercareer.com/` returns 404, but something *is*
listening on 5018, so the tunnel reaches it — that is the other app's own response
to `/`, not a tunnel fault.

### 7. Final check before announcing it
- [ ] `/api/tickets` returns 401 when logged out
- [ ] Seeded passwords rotated (step 4)
- [ ] `/glimpse.axd` returns 404
- [ ] An error page shows no stack trace
- [ ] Employee account cannot resolve a ticket by editing the URL

---

## Known issues, deliberately deferred

- **`ViewTicket` mutates state over GET with no antiforgery token.** ~~Deferred~~
  **WON'T FIX — decided 2026-09-21.** John reviewed the issue and declined; the app
  holds no real data and the worst case is spam comments on a demo. Do not raise it
  again unless he asks.

  For reference if that ever changes: the action writes on GET (resolve + comment),
  so `<img src="/Home/ViewTicket?ticketId=5&commentTextBox=x">` on any page posts a
  comment as whoever visits it. The fix is to split it into `ViewTicket` (GET,
  display only), `AddComment` and `ToggleResolved` (both POST +
  `[ValidateAntiForgeryToken]`), then update `ViewTicket.cshtml`,
  `EmployeeViewTicket.cshtml` and `NewCommentView.cshtml`. The resolve forms already
  use `method="post"`; the action just lacks `[HttpPost]`, so it accepts both verbs.
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

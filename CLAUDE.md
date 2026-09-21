# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A bug/issue tracker web app ("Bugtracker"). Classic **ASP.NET MVC 5 on .NET Framework 4.7.2** — not .NET Core. Assembly/root namespace is `FinalProReRe` (note: the `ViewModels/` folder uses a different, misspelled namespace `FinalProRere.ViewModels` — keep it, changing it breaks every `@model` directive).

## Build & run

There is no `dotnet` CLI path and no test project. Use MSBuild + NuGet restore (packages are restored into `packages/`, referenced by hint path in `FinalProReRe.csproj`):

```powershell
nuget restore                    # or: msbuild /t:Restore
msbuild FinalProReRe.sln /p:Configuration=Debug
```

Normal development is F5 in Visual Studio (IIS Express). The dev database is LocalDB (`(LocalDb)\mssqllocaldb`, catalog `FinalProReRe`) per the `DefaultConnection` string in `Web.config`.

Entity Framework 6 migrations run from the Visual Studio **Package Manager Console** (`AutomaticMigrationsEnabled = false`, so every schema change needs an explicit migration):

```powershell
Add-Migration <Name>
Update-Database
```

## Deployment

`.github/workflows/master_bugtracker.yml` builds on every push to `master` and deploys to Azure App Service (`Bugtracker`, Production slot) via OIDC login. The build step uses `msbuild /t:Build /t:pipelinePreDeployCopyAllFilesToOneFolder` — the project must stay MSBuild-publishable; don't introduce anything requiring `dotnet publish`.

## Architecture

**Authorization is the core domain concept.** Two ASP.NET Identity roles, seeded by SQL inside migration `202010021455391_canmanageticketrole`:

- `CanManageTickets` — manager. Can add and delete tickets, toggle Resolved.
- `CanViewTicketsOnly` — employee. Read-only plus commenting.

Roles gate behavior two ways, and both must be kept in sync when adding features:
1. `[Authorize(Roles = "CanManageTickets")]` on manager-only actions (`AddTicketForm`, `DeleteTicket`).
2. `User.IsInRole("CanViewTicketsOnly")` inside actions to *switch which view is rendered* — `EmployeeIndex` returns `LimitedEmployeeIndex.cshtml` instead of `EmployeeIndex.cshtml`, and `ViewTicket` returns `EmployeeViewTicket.cshtml` instead of `ViewTicket.cshtml`. So most manager/employee pages exist as **parallel view files with duplicated markup**; a UI change usually has to be made in both.

`HomeController` is `[Authorize]` at the class level — everything requires login. Self-registration is deliberately commented out in `AccountController` (the block that would have granted `CanManageTickets` to any new signup). Seeded test accounts are in `ReadMe.txt`.

**Two parallel stacks over one DbContext.** `ApplicationDbContext` (`Models/IdentityModels.cs`) extends `IdentityDbContext<ApplicationUser>` and adds `Tickets` and `Comments`. It is served by:
- MVC (`Controllers/HomeController.cs`) — server-rendered Razor, form posts, redirects.
- Web API (`Controllers/Api/TicketsController.cs`) at `/api/tickets` — JSON, camelCased (`WebApiConfig`).

The index pages render an **empty `<table id="tickets">`** and fill it client-side: an inline `XMLHttpRequest` to `/api/tickets` feeds jQuery DataTables. So the ticket list's columns are defined in the view's `<script>` block (`EmployeeIndex.cshtml`, `LimitedEmployeeIndex.cshtml`), keyed by the API's camelCase JSON property names — changing a `Ticket` property name silently empties a column unless the DataTables `"data"` key is updated too.

Controllers `new` up their own `ApplicationDbContext` in the constructor (no DI container). `HomeController` overrides `Dispose`; the API controller does not.

**`ViewTicket` is a multi-purpose GET.** One action handles viewing, resolving/unresolving (via `Resolved` as the string `"true"`/`"false"`), and comment creation (via `commentTextBox`), all from query-string/form values on a non-`[HttpPost]` action with no antiforgery token. Note it does not re-check `CanManageTickets` before flipping `Resolved`.

**Layout is mostly bypassed.** `Views/_ViewStart.cshtml` sets `Layout = null`, so `_Layout.cshtml` is effectively dead for the ticket pages — each view is a full standalone HTML document that calls `@Styles.Render("~/Content/css")` and `@Scripts.Render(...)` itself. Bundles are defined in `App_Start/BundleConfig.cs`; the jQuery bundle also carries DataTables.

`Comment` stores both a `name` string (copied from `User.Identity.GetUserName()` at write time) and an `ApplicationUserId` FK — only `name` is actually populated by `HomeController`.

Glimpse (diagnostics at `/glimpse.axd`) is wired into `Web.config` and gated by `GlimpseSecurityPolicy.cs`.

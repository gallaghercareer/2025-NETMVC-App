Demo accounts
=============

Two accounts are seeded by the migration 202010021455391_canmanageticketrole:

  admin@hiring.com      role: CanManageTickets   (add/delete tickets, resolve)
  employee@hiring.com   role: CanViewTicketsOnly (read and comment only)

The passwords originally committed here were removed, and the seeded password
hashes were rotated on the deployed database (.\MSSQLSERVER02, catalog
FinalProReRe) on 2026-09-20. The hashes still in
the migration file are public via git history, so ANY database created by running
Update-Database is seeded with known-compromised credentials and must be rotated
again before that instance is exposed.

To rotate, generate a hash with the Identity PasswordHasher and update both the
hash and the SecurityStamp (rotating the stamp invalidates existing auth cookies):

  Add-Type -Path packages\Microsoft.AspNet.Identity.Core.2.2.3\lib\net45\Microsoft.AspNet.Identity.Core.dll
  $h = (New-Object Microsoft.AspNet.Identity.PasswordHasher).HashPassword('<new password>')

  UPDATE AspNetUsers SET PasswordHash = '<hash>', SecurityStamp = '<new guid>'
  WHERE Email = 'admin@hiring.com'

Do not set PasswordHash to NULL - the account cannot log in and there is no
password-reset email flow configured to recover it.

The current live passwords are not stored in this repo.

Other docs
==========

  RUNBOOK.md      START HERE if you are coming back to this cold. How the live
                  site runs (Cloudflare -> cloudflared -> IIS -> w3wp -> SQL),
                  how to deploy a change, what to check when it breaks, and the
                  things that look broken but are not.

  DEPLOY-TODO.md  The build log: how it got set up, what was decided and why,
                  and the issues that were looked at and deliberately left.

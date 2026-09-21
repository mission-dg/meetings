# Shift workspace upgrade — 2026-09-21

## What is implemented in this package

- Distinct IT, Manager, and Employee layouts, authorized view switching, per-account remembered view, separate landing pages, enhanced Employee View for CAs, and server-side employee-safe projections even for IT accounts.
- Existing weekly drafts, reviewed/locked timed releases, trades, linked training, announcements, password sign-in, and invitation gate.
- Inclusive temporary availability with restoration of regular hours, explicit replacement of overlapping temporary approvals, PTO/RTO classification and paid hours, approved-time-off cancellation requests, approved absences on the manager board, and immediate conflict warnings for drafts/queued releases.
- IT role assignments for existing employee accounts, preserving the Staff ID and training records. Linked SHL accounts have one roster identity and are exempt from six-month meeting eligibility. Demoting SHL access preserves the employee login. Disabling the employee account disables its linked manager access. Existing GM/last-IT protections remain.
- Daily briefs, private manager logbook/tasks/history, in-app operational/birthday reminders, optional contact sharing, private emergency contacts, versioned documents with separate open/download/read activity, printable schedules, operational reports, and revocable personal calendar subscriptions.
- Labor planning with effective-dated rates, sales forecasts, explicit missing rates, draft/published estimates, all-SHL viewing, and GM/IT rate maintenance. These are not payroll calculations.

## Current release status

Source is implemented and locally validated. This is not a declaration that the complete roadmap or production rollout is finished.

A fresh owner-only snapshot and a separate local recovery export were captured on 2026-09-21 at 18:52 UTC. They preserve 40 staff, 6 meetings, 2 training sessions, and the associated notes, setup, and history. Production still requires installation of migrations 009–015, private storage policies, the account-service update, the calendar-feed function, and deployment of this frontend. Actual hosted Cron execution, separate live employee/CA logins, SMTP delivery, calendar subscription refresh, and storage downloads must be verified before employee access is enabled.

Multiple locations, hiring/applicant handling, and dedicated native applications remain later roadmap phases. They are not represented as working features or exposed through decorative navigation. Do not enable multiple locations until every API and direct table/storage access is location-scoped and tested. Native distribution follows stable web workflows and the organization’s store-account setup.

Schedulefly remains the official schedule until the agreed cutover. The pilot must cover at least two complete weekly cycles. Do not activate invitations or announce a cutover merely because the code builds.

## Installation order

1. Run `supabase/maintenance/backup_before_workspaces.sql` in the existing project. Keep the original `before-scheduler-009` backup. Export the owner-only snapshot to secure owner-controlled storage; never commit live records or auth secrets.
2. Check the existing schema version. `INSTALL_WORKSPACES.sql` is a one-time atomic upgrade for the current database with 001–008 already applied and 009 not yet installed. Do not run it against a database already upgraded through 009; use only the missing individual migrations there.
3. Install the tested SQL package. It includes migrations 009, 011–015, then 010 to register the stable release worker. The worker checks every minute, with daily reminders after 6 AM Central. No employee accounts, role assignments, pay rates, or schedules are seeded.
4. Deploy the updated `manage-accounts` function and `calendar-feed`. `calendar-feed` deliberately accepts a revocable subscription token instead of a login JWT; its underlying RPC is executable only by the service role. Never log calendar URLs or tokens.
5. Keep `APP_URL=https://mission-dg.github.io/shift/`, the matching Supabase auth redirect, and the GitHub Pages `/shift/` base.
6. Deploy the frontend only after the new RPCs exist. Verify owner login, all authorized views, and private workspace responses.
7. Use a test environment and separate test identities to exercise Employee/CA/SHL/IT API access, training, approvals, documents, and calendar feeds. Local SQL tests are not substitutes for hosted-service checks.
8. Configure Resend using a verified sending domain and verify an invitation and a password reset. Record the evidence in IT View before enabling employee invitations. No operational email, SMS, or push delivery is implemented.
9. Begin the limited pilot. Reconcile future schedules and approved restrictions before a Sunday cutover.

## Recovery and privacy

- Database changes are additive. Preserve new records if reverting the frontend; the earlier scheduler APIs remain callable.
- A backup in the same database is useful for application recovery but is not disaster recovery. Keep a protected export/database backup separately.
- Do not blindly restore a pre-upgrade snapshot after people start using Shift. Reconcile newer schedules, decisions, notes, and training first.
- Directory contact preferences do not change the account’s sign-in email. Emergency contacts are requester/manager-only.
- Files use a private bucket; generated download links expire after 60 seconds. Previously generated links remain valid until expiry.
- Calendar links confer access to minimal personal commitments. Resetting/revoking a link invalidates future retrieval; disabling an account permanently deletes its token. Calendar clients can retain previously downloaded data.
- Payroll, balances/accrual, automatic schedule generation, clocking in/out, chat, operational outbound alerts, and offline edits are absent by design.

## Validation

Run `npm test` and `GITHUB_ACTIONS=true npm run build`. The tests apply actual PostgreSQL migrations in PGlite, test role/record isolation and mutations, and cover permanent IDs, old tracker behavior, temporary availability, time-off cancellation, role linking, private storage policies, feed revocation, and cost/calendar calculations.

The disconnected preview uses fictional accounts. Changing the demo account is explicitly a local simulation, not live impersonation. Resource writes require a connected test account and report that clearly. The ordinary Workspace view switcher always preserves the signed-in identity.

> **Workspace upgrade:** The distinct Employee/Manager/IT workspaces and migrations 011–015 are documented in [WORKSPACE-UPGRADE.md](WORKSPACE-UPGRADE.md). Use that versioned installation sequence for the complete upgrade. Live activation, verified email delivery, and the pilot remain required.

# Scheduler release 0.2 — installation and verification

This package upgrades the existing Mission Meetings project after migrations 001–008. It preserves permanent IDs and all meetings, notes, requests, training, and qualifications. Do not rerun the initial migrations or reseed the roster.

## Installation order

1. Preserve existing records with `supabase/maintenance/backup_before_scheduler.sql`. The repeatable-read snapshot is stored in the owner-only `private.scheduler_backups` table under `before-scheduler-009`; rerunning the script does not replace it. It contains application records, previous function definitions, and policies, not authentication secrets. Record counts must match before proceeding. Keep a separate project backup/export for disaster recovery; this snapshot protects the upgrade within the existing project.
2. Review and install `supabase/migrations/009_scheduler.sql` once. It introduces employee/CA access, safe scheduler APIs, private draft storage, linked training, invitation reservations, and audit history. It does not create employee accounts, send email, or change the existing manager/IT/GM roles. Existing IT accounts without the GM designation start off the work roster; IT can include them through People & access.
3. Install `supabase/migrations/010_scheduler_cron.sql`. The named `mission-schedule-release` job calls the private release worker every minute. Reapplying this small cron script updates the named job rather than making another copy. Scheduler 009 itself is a one-time migration.
4. Replace the deployed `manage-accounts` Edge Function with `supabase/functions/manage-accounts/index.ts`. Preserve the existing APP_URL, server-supplied Supabase credentials, and handler-side token verification. Keep the gateway configuration in `supabase/config.toml`; no service key belongs in the frontend.
5. Run `npm test` and `GITHUB_ACTIONS=true npm run build`, then publish this frontend from `mission-dg/shift`. Do not publish it before the database upgrade. Normal sign-in remains password-based; no public registration.
6. Open the real website as the current IT Admin. Verify Schedule, Availability, Requests, Training, Announcements, People & access, and Meetings & staff. Compare the live legacy record counts with the backup. Test a private draft without releasing real shifts accidentally.
7. Verify the cron job's successful check time advances while browser windows are closed. In the Supabase owner SQL editor, inspect `private.scheduler_settings` and `cron.job_run_details` for the named job. Queued releases are transactional, but server downtime can delay execution; the UI flags stale checks, and a delayed release that would first reveal started shifts is held for review.
8. Leave employee invitations disabled until the email and distinct-account checks below pass. Do not use SQL to bypass the delivery gate for ordinary rollout.

## Email prerequisite

Resend's `resend.dev` sender is limited to the email address on the Resend account. Invitations to employees and dependable resets need a verified sending domain. An existing domain or dedicated subdomain can be used only for email while the website remains on GitHub Pages. A GitHub Pages address is not a domain whose DNS you can verify in Resend.

Configure Resend's SMTP details in Supabase Authentication → Email/SMTP. The owner enters the API key there, never in code or chat. Keep the normal Supabase confirmation URL templates and exact allowed redirect URLs. Test an invitation and a password reset to an intended recipient; the recipient sets the password themselves. Then IT records the sender/date/results in People & access → Email delivery readiness and enables invitations. Regular password sign-in sends no email.

Managers can invite an existing employee only at employee access. IT grants/removes CA through People & access. Existing SHL invitations, manager activation, GM designation, and IT controls remain in Meetings & staff → IT Admin. CA is independent of primary job and does not add a manager profile.

## Daily use

- **Schedule:** Select a Sunday-start week. Create a draft or copy the previous published week's work shifts. Copying assigns new shift IDs, preserves Central wall times, and does not copy training sessions. Add shifts, jobs/SHL, Shift 1/2, and flexible start/end times. End dates may be the next day. Each form saves the shared manager draft privately.
- **Review & release:** Review added/changed/cancelled shifts, training, and issues. Release immediately or choose a future Central timestamp. Ambiguous fall times require an occurrence choice; spring-forward gaps are rejected. A queued revision is locked. Cancel its release to edit it or change its release time. Employees see the last publication throughout.
- **Release needs attention:** Resolve the reported problem and requeue. If a trade changed the publication underneath the draft, use Reload published version, then recreate intended edits; the old draft values stay in change history. Move or cancel attached draft training first when requested.
- **Availability:** Employees select Set availability, choose an effective date and weekly hours (all day, unavailable, or one or more time windows). Current approved hours are prefilled. Use both days for overnight availability. Submit for manager approval; pending or denied changes leave the current approval in effect. Managers review every weekday, approve or deny with a response, and use Approved team availability to look up current/future approved hours. Decisions include the manager and time. A manager cannot approve their own request. Conflicting published shifts must be resolved before approval, and releases enforce approved availability. Pending requests can be withdrawn.
- **Requests:** Employees submit full/partial time off, trades, specific coverage, or open offers. Availability requests are also visible here. A coworker accepts/claims shift changes before a manager decides. Pending availability has no effect. Approval rechecks current published assignments; resolve conflicts before approving. Another manager must decide a manager's own request. Reasons are visible only to requester and managers.
- **Training:** Managers plan against drafts or published shifts; CAs use published shifts. Pick the trainee's and trainer's work shifts, job, and actual training interval. Both must be working throughout it. Only the session creator edits it or records its outcome. Explicit completion counts once per employee/job/Central date/Shift 1 or 2. Four is the default target; manager readiness sign-off remains separate. Legacy sessions retain their original timestamps and missing links/end times.
- **Announcements:** Managers/CAs publish to everyone or selected groups. Only the author edits or archives a post. Changed content becomes unread again; author revision history is available. The inbox also shows releases and request activity. These are in-app notices, not background phone alerts.
- **Employees:** My schedule and published team shifts, own meetings/training, own qualifications, requests, and relevant announcements. Phone screens use readable daily cards. Employees/CAs receive no meeting notes, priority flags, GM requests, private assignment explanations, or general audit history.

## Verification and limits

Automated tests run the real migration in PGlite with distinct authenticated manager, CA, employee, unapproved, and inactive identities. They cover access projections and direct table denial, locking/version checks, idempotence, cross-week swaps with rollback, competing claims, availability/time-off, training ownership and shift coverage, DST handling, stale/delayed/revoked-manager releases, and invitation reservation/error paths. Existing meeting, removal, role, ID, and qualification tests remain in the suite. PGlite tests exercise the worker itself; they do not prove the hosted cron extension or email provider is running.

Before enabling actual employee access, exercise real separate employee, CA, and manager logins: draft invisibility, published shifts, no private columns through direct API calls, CA's own training edits only, manager-only sign-off, announcement audiences, invitation linking, and employee deactivation. Send no real announcements or shifts merely to test the interface. Scheduled hours are planning totals only.

## Recovery

- Keep the existing website available until the database and function upgrades pass. If a frontend problem occurs after deployment, revert the frontend commit; preserve the database and its new records. Do not drop scheduler tables or restore all old records over newer work.
- Pause releases if needed with the owner SQL `select cron.unschedule('mission-schedule-release');`. Reinstall 010 after correcting the issue. A queue can also be cancelled by a manager in the app without losing the publication/draft.
- The backup is read-only to app users. An owner can inspect `select * from private.scheduler_backups where id='before-scheduler-009';`. Restore selectively into a separate test project first using migrations 001–008 and the saved records, preserving foreign-key order and permanent IDs; compare newer records before any production recovery.
- Invitation uncertainty fails closed: do not repeatedly send. IT checks `private.employee_invitations`, matches the email to the existing Supabase Auth user, and uses `finish_employee_invitation(reservation_uuid, auth_user_uuid)` in the owner editor only after verifying identity. This links employee access without granting CA/SHL/IT. Do not delete Auth users to retry. If no invitation was created, correct the delivery issue and have IT explicitly review the reservation before resetting/retrying it.
- Access removal is reversible and preserves history. Staff removal still requires the person's exact `Remove First Last` phrase followed by `Confirm`; it also immediately prevents their linked employee account from accessing the workspace.

References: [Supabase Cron](https://supabase.com/docs/guides/cron), [Resend sender restrictions](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain).

## Recorded rollout status — September 21, 2026

- Live backup saved at `2026-09-21 09:44:04 UTC`, key `before-scheduler-009`.
- Preserved counts: 40 staff, 1 manager, 6 meetings, 1 note, 0 GM requests, 2 training sessions, 6 jobs, 0 sign-offs, 72 audit rows, 1 import batch, 1 tracker setup row.
- 23 automated test groups and production build passed. Desktop preview: draft edit, release review/queue lock, employee publication privacy; narrow layout: daily schedule cards and employee request form; CA: published-shift training picker.
- Availability follow-up: employee submission → manager review/approval → approved hours lookup verified in the disconnected browser demo, including a narrow phone layout. Pending/denied changes, effective dates, published-shift conflicts, split windows, adjacent windows, private reasons, and approval permissions verified with database tests. The preview keeps fictional availability changes across role switches until reloaded.
- Scheduler migrations, cron, updated account function, live distinct-role login checks, and frontend publishing are pending. Invitation delivery is unverified and remains disabled.

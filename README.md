# DG Mission Meetings

Deployment repository: https://github.com/mission-dg/meetings. The local folder may retain its original name; its Git remote determines the destination.

Private manager workspace. React + TypeScript + Vite frontend; Supabase Auth and Postgres backend. GitHub Pages hosts only the static application, never staff records or notes.

## Current status

Migrations 001–008 are installed in the connected project. Scheduler release 0.2 is built and tested locally; its live installation and employee rollout are tracked in [SCHEDULER-SETUP.md](SCHEDULER-SETUP.md). Follow that checklist before publishing this frontend. Employee invitations remain disabled until a verified sender and successful invitation/reset delivery are recorded.

The scheduler adds weekly private drafts, queued server releases, employee/CA views, requests and shift trades, linked training, and in-app announcements. Meetings & staff keeps the existing manager tools and six-month rules. The development preview uses fictional data and in-memory draft demonstrations; it does not change live records or send email. Preview access is disabled in production.

The sections below document the original tracker and its incremental migrations. Scheduler 009 replaces the earlier standalone-training creation rules: new training requires work-shift links and an end time, and work times may extend outside customer opening hours. Earlier standalone records remain intact.

## 1. Create Supabase

Create a new project in your Supabase account. Store the database password privately; it never belongs in this repository or frontend.

In the SQL Editor, run `supabase/migrations/001_tracker.sql`, then `supabase/migrations/002_admin_import.sql`, then `supabase/migrations/003_admin_bootstrap.sql`, once each on the new project. It creates the tables, access policies, constraints, and audit triggers. Test on a new project first; this migration is not an upgrade for another application.

Authentication settings:

- Turn **Allow new users to sign up** off.
- Enable Email authentication (password sign-in, invitation links, and password recovery).
- Set Site URL to `https://mission-dg.github.io/meetings/`.
- Add exactly that URL to allowed redirect URLs. For local development, also allow `http://localhost:5173/` and `http://127.0.0.1:5173/`.
- Configure production email delivery before inviting your manager team. Supabase's built-in test email delivery has recipient/rate restrictions.

The site requests sign-in links with `shouldCreateUser: false`; disabling signups on the server is also required. Password sign-in is the default; passwords are sent directly to Supabase Auth and are never stored in app records. Email links remain optional.

## 2. Approve your first IT Admin and GM

Create/invite the first IT Admin and GM accounts in the Supabase Authentication dashboard. Copy their UUIDs. If these are two people, run the following **together**, substituting their UUIDs and names:

```sql
begin;
insert into public.manager_profiles (id, name, active, is_gm, is_admin)
values ('IT-ADMIN-AUTH-UUID', 'IT Admin name', true, false, true),
       ('GM-AUTH-UUID', 'GM name', true, true, false);
commit;
```

If you personally hold both roles, create just one row with both booleans true. Roles remain independent: IT Admin does not grant the GM’s special-meeting authority, and neither role overrides creator-only editing. You may create only the IT Admin first with `is_gm=false`. Migration 003 allows the GM to remain unassigned during initial setup. After the first active GM is assigned, a replacement is required before removing that designation.

After bootstrap, use **IT Admin → SHL accounts** for invitations, new sign-in links, names, activation, IT Admin access, and GM reassignment. Another IT Admin must remove your own administrator access. Assign a replacement before deactivating the current GM. Open linked GM bookings must be resolved or cancelled before transferring the designation.

### Install the account service

In Supabase’s Edge Functions dashboard, create a function named `manage-accounts` and paste `supabase/functions/manage-accounts/index.ts`, then deploy it. Set the function secret `APP_URL` to `https://mission-dg.github.io/meetings/`. Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions; these stay on the server. The function verifies the user token and checks active IT Admin status on every call. With new asymmetric signing keys, disable the legacy gateway JWT check for this function; the handler still verifies identity using `auth.getUser`. This configuration is also in `supabase/config.toml` for CLI deployment.

Configure SMTP before inviting other managers. Keep the standard invitation and magic-link email templates using `{{ .ConfirmationURL }}`. The browser uses Supabase’s client-only implicit flow so an admin-sent link works in the recipient’s browser without a verifier stored in the admin’s browser. Tokens arrive in a URL fragment and are consumed by Supabase Auth.

If invitation email succeeds but profile approval fails, the UI explicitly reports partial completion. Repair the new user’s profile in Supabase using the UUID and a non-GM profile row; do not delete existing accounts to retry. An unapproved account cannot read workspace data. Existing approved users should receive a fresh sign-in link, not another invitation.

### Employee import

Use **IT Admin → Import employees → Download CSV template**. Columns: First Name, Last Name, Position, Active. Position is FOH, HOH, or Catering; Active accepts Yes/No, true/false, 1/0, or blank for Yes. Preview the file, then import up to 500 rows (1 MB). Permanent IDs are generated by the database. Imports skip matching full names case-insensitively across all departments, including inactive records and repeated rows. They never modify existing employees. Add true namesakes individually using Staff directory.

Imports are transactional: invalid data saves nothing. Retrying the same submission returns its previous result; reuploading a file also skips existing names. Staff imports do not create login accounts.

## 3. Connect the frontend

Copy the **Project URL** and **publishable key** from Supabase's project connection/API settings. Do not use a secret or service-role key.

Local development: copy `.env.example` to `.env.local` and fill both values. The `.env` files are ignored by Git.

GitHub: go to repository **Settings → Secrets and variables → Actions → Variables** and create:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

These two values are intentionally public browser configuration. Data privacy comes from authenticated database policies. Never put administrative credentials into a `VITE_` value.

## 4. Publish GitHub Pages

1. Commit and push the project to `main`.
2. In **Settings → Pages**, set **Source → GitHub Actions**.
3. Open **Actions → Publish website**. Run it manually if needed after enabling Pages or changing repository variables.
4. Wait for the build and deployment to succeed.
5. Open the URL reported by that workflow. Expected address: `https://mission-dg.github.io/meetings/`.

The expected address is not proof of deployment. The workflow's successful deployment is the authoritative result. Until Supabase variables are supplied and the site is rebuilt, it shows the setup screen.

## Local development and verification

Use Node 24 (the deployment workflow uses Node 24).

```sh
npm ci
npm test
npm run build
npm run dev
```

Visit the development server normally to inspect sign-in, or append `?preview=1` to see a fictional dashboard. The preview does not authenticate, store records, or connect to Supabase. Production builds disable it.

Tests execute the actual migration against an embedded Postgres-compatible engine. They check public/unapproved/inactive access, shared reads, creator-only writes even for the GM/admin, ownership spoofing, stale versions, audit history, duplicate routine bookings, GM-only special meetings, and linked request completion. Run a live test with two separate manager accounts before adding real staff notes.

Dates and six-month deadlines use America/Chicago. Month-end deadlines clamp to the last valid day. Scheduled timestamps are stored in UTC. Spring daylight-saving gaps are rejected; repeated fall times choose the earlier occurrence.

## Before real use

Verify signed-out access is denied, both managers can see a test meeting/note, only the creator can edit each record, and deactivation removes access. Verify email delivery, request completion, and a fresh login after reopening the browser. Database project creation, applying the migration, and these live account tests are still required.

Supabase project owners can administer the database outside this app. Creator-only editing describes application-account permissions, not an inability for the database owner to maintain the database.

## Reference and verification

Visual reference: [MISSION BBQ official website](https://mission-bbq.com/) — charcoal navigation, orange accents, condensed headings, and warm neutral surfaces. The three meeting-label colors remain distinct. No corporate photos or imitation logo were added.

Auth reference: [Supabase implicit flow](https://supabase.com/docs/guides/auth/sessions/implicit-flow). Account invitation API: [inviteUserByEmail](https://supabase.com/docs/reference/javascript/auth-admin-inviteuserbyemail).

Local tests cover real SQL access policies, creator-only notes and meetings, admin-only operations, stale role changes, GM transfer, import rollback/retries, Staff ID collisions, and malformed CSV. The Edge Function handler is tested with mocked Auth responses; actual email delivery and live Supabase login still require the project and SMTP configuration. After connection, exercise invitation → email → login, inactive-account rejection, two-manager shared viewing/creator-only editing, and a small employee import before loading a real roster.

## Trainers and training sessions

Install `supabase/migrations/004_training.sql` after migration 003 before publishing this frontend. The migration was installed successfully in the connected project on September 21, 2026. It preserves existing records.

1. IT Admin: open Staff directory → Edit, select **Trainer**, and save. Trainers remain employees without website accounts.
2. Managers: open **Schedule meeting → Meeting type → Training** (or Meetings → **Schedule training**). Choose FOH, HOH, or Catering, employee, trainer, Shift 1 or Shift 2, date, and Central start time. One trainer belongs to each session; the same employee can have different trainers on later shifts or days.
3. Teal calendar entries show **start time · Trainer Training Employee**, plus shift. Click one to view details. Its creator can reschedule, complete, mark missed, or cancel it. All active managers can view it.

Shift numbers do not imply fixed times. Starts must be within Sunday 11:30 AM–8 PM or Monday–Saturday 11 AM–9 PM (closing time excluded). No end time or overlap checking is implied. Training never resets six-month meeting eligibility, clears manual priority, or resolves GM requests. Existing sessions remain in history if a trainer is deactivated or loses their designation.

Validation: SQL tests cover opening hours, multiple trainers over days, staff eligibility, shift values, shared reads, creator-only edits, stale updates, audit history, anonymous denial, and unchanged meeting reminders. Preview checks cover department-first selection, shift selection, validation, and calendar display.

## Positions and Catering

Migration 005 adds Catering without changing existing IDs or records. User-facing positions are FOH, HOH, Catering, and SHL (managers). The existing database field `department` and stored `BOH` value remain compatible; BOH displays as HOH. CSVs accept Position/Department headers and HOH/BOH values. SHLs appear in the staff directory and are managed through SHL accounts, preserving login permissions and their exemption from employee meeting reminders.

Migration 005 was installed in the connected Supabase project on September 21, 2026. All six test groups and the production build passed. The website change must still be pushed to GitHub to publish.

## Password sign-in

The sign-in page defaults to email and password. Existing invited accounts can use their signed-in session and **Set / change password** in the sidebar. New invitations and recovery links open the password setup screen. Choose and confirm a password of at least 12 characters. Recovery remains available through **Forgot password?**; this sends email and shares the email sending quota. Password sign-in does not send email. Public registration remains disabled and all existing manager access checks remain in place.

If you are signed out everywhere and never set a password, wait until the email quota resets, request one sign-in link, then set a password. A previously consumed link cannot be reused. Publish the frontend update before requesting a recovery link. Custom SMTP remains necessary for reliable invitations and recovery emails; this change does not increase the email quota. Browser sessions already persist and refresh automatically; sign out when finished on a shared computer.

Validation: production build, existing permission tests, and browser checks of password/default and recovery navigation passed. A real account password setup and subsequent login require the account owner to enter their password; this has not been performed by the agent.

Training can now be created from the standard meeting form. Selecting Training replaces the manager field with a required active Trainer selector and a Shift selector. The save uses the existing training-session store, so training does not count as a six-month meeting. Existing meetings and GM-linked bookings keep their original record type. No new database migration is needed. Browser checks verified missing-trainer blocking, Routine/Training switching, and a valid preview submission.

## Training progress and manager sign-off

Migration `006_training_progress.sql` was installed in the connected Supabase project on September 21, 2026. It adds six requested jobs (FOH: GSR, EXPO, DRL; HOH: Line, Prep; Catering: Catering), each with a default target of four shifts. Existing sessions remain untouched with no job assigned until their creator chooses one. New training sessions require an active training job. Publish this frontend promptly after migration so the scheduling form includes that required field.

Use **Training progress** to see each employee/job pair, completed shifts, remaining shifts, scheduled bookings, and history showing trainers. Only explicit Completed sessions count. The same employee/job/local-date/shift counts once even if it has multiple sessions. Future sessions cannot be marked completed. Targets use Shift 1/2 and Central dates, without fixed shift start times.

At the target, the status is **Ready for sign-off**. Any active manager may confirm readiness; the status becomes **Fully trained** and retains the manager and timestamp. The sign-off creator can reopen it. All managers can read progress; existing creator-only editing applies to sessions and confirmations. The IT Admin can add, rename, archive jobs, or adjust their targets (1–30 shifts). No permanent deletion is offered. If a changed target/history leaves fewer completed shifts than the target, the display shows In training with the earlier sign-off retained as history.

Older sessions appear under **Training needs a job**. Their creator can use **Choose / correct training job** in session details without changing the time or outcome. Completed legacy sessions count after assignment. Training job membership is independent of the employee’s home position group, allowing cross-training. Training never resets meeting reminders or resolves GM requests.

Verification: eight test groups pass, including actual SQL migration/policy/target/stale-update checks, preserving legacy records, job seeding, duplicate-shift counting, and date/timezone cases. Browser checks verified 2/4 progress, 4/4 Ready for sign-off, the job catalog, and prefilled next-shift scheduling. No live employee qualification was signed off during validation.

## Employee removal and IT role testing

Migration `007_staff_removal_it_roles.sql` adds typed employee removal and IT-role changes. The user approved installation, and migration 007 was installed successfully in the connected Supabase project on September 21, 2026. No existing account roles or employee statuses were changed during installation.

IT Admins can use **Staff directory → Remove**. The confirmation window requires exactly `Remove FirstName LastName` and then `Confirm`, including capitalization and spacing. The server checks the phrases against the current stored name. Removal sets Active to false; IDs, meeting/training/request history, notes, and open bookings remain. The window lists open meetings and training involving the employee (including trainer assignments). To restore them, choose Staff directory → All → Edit → Active employee. Active staff must use the removal window instead of an unchecked Active field.

IT Admins and the active GM can use **IT Admin → SHL accounts → Grant / Remove IT access**. A review panel identifies the account and intended change. The new server function changes only IT membership, preserving manager/GM roles and active state. Ordinary or inactive managers cannot call it. It checks profile versions, serializes competing role changes, preserves at least one active IT Admin, and records changes in the existing audit history. Self-demotion is allowed when another active IT Admin remains; a GM may promote themselves for testing. Invitations, roster editing, and general account editing remain IT-only. No actual account was promoted or demoted during validation.

Validation: nine test groups pass, including typed-name mismatch/rename cases, history preservation, unauthorized callers, GM promotions/demotions, self-demotion, stale changes, inactive targets, and last-admin protection. Browser checks confirmed both phrases are required exactly and the role-change review panel names its target.


## Primary jobs and additional qualifications

Migration `008_primary_jobs.sql` was installed successfully in the connected Supabase project on September 21, 2026. It adds an optional primary job to each employee without changing existing IDs, bookings, or training history. Existing employees start with no primary job assigned. IT Admins choose it in **Staff directory → Edit → Primary job**; the job must be active and in the employee’s FOH, HOH, or Catering group. The directory shows and filters by primary job, and the scheduling form offers the same lookup filter.

The primary job is independent of qualifications. Employees can train in any number of other jobs, including jobs in another position group. Each employee/job pair retains its own completed-shift count, target, and manager sign-off. Select the job being learned when scheduling each training session. **Training progress** labels each row as Primary job or Additional job, and the directory shows additional-job progress. Changing a primary job or transferring groups preserves every training session and sign-off. Assigning a primary job does not mark someone fully trained.

An archived primary job stays attached until deliberately reassigned, but cannot be newly assigned. Before changing the position group of a job used as someone’s primary job, reassign those employees. General staff editing remains IT-only, and meeting/training creator permissions remain unchanged.

Validation: ten test groups pass, including an employee completing and receiving sign-off in all six jobs; primary-job changes and transfers preserve all 24 sessions and six qualifications. Server checks reject mismatched groups, archived new assignments, and unauthorized edits.

Browser checks verified primary-job filtering, group-specific choices, cleared incompatible selections, and scheduling a secondary Line session for an employee whose primary job remains GSR. Unchanged forms close without a warning. The production build passes.

# DG Mission Meetings

Deployment repository: https://github.com/mission-dg/meetings. The local folder may retain its original name; its Git remote determines the destination.

Private manager workspace. React + TypeScript + Vite frontend; Supabase Auth and Postgres backend. GitHub Pages hosts only the static application, never staff records or notes.

## Current status

Supabase project `jgekdmnfakagmuudywmb` is configured: migrations 001–003 are installed, the account service is deployed, public registration is disabled, and GitHub has the public connection variables. The initial IT Admin is active; the GM has not yet been assigned. The owner confirmed successful invitation sign-in to the live Meeting Tracker overview. Other authenticated editing workflows still need live verification; custom SMTP is not configured yet. A development-only visual preview contains fictional examples and disables saving; it is not included as a usable route in production.

Implemented: dashboard, staff directory, scheduling/rescheduling, completed/missed/cancelled outcomes, shared notes, creator-only editing, GM requests and links, six-month labels, database audit history, permanent staff IDs, IT Admin account management, employee CSV imports, and MISSION BBQ-inspired styling. This is a new empty project; no spreadsheet records have been imported. Full historical-entry/correction screens and Calendar integration are follow-up work.

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

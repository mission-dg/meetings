# DG Mission Meetings

Private manager workspace. React + TypeScript + Vite frontend; Supabase Auth and Postgres backend. GitHub Pages hosts only the static application, never staff records or notes.

## Current status

The website and database migration are ready for connection. There is **no live Supabase project configured**. Without configuration, the site displays an honest setup screen and cannot sign in or save. A development-only visual preview contains fictional examples and disables saving; it is not included as a usable route in production.

Implemented: dashboard, staff directory, scheduling/rescheduling, completed/missed/cancelled outcomes, shared notes, creator-only editing, GM requests and links, six-month labels, database audit history, and permanent staff IDs. This is a new empty project; no spreadsheet records have been imported. Full historical-entry/correction screens, account administration inside the GUI, and Calendar integration are follow-up work.

## 1. Create Supabase

Create a new project in your Supabase account. Store the database password privately; it never belongs in this repository or frontend.

In the SQL Editor, run `supabase/migrations/001_tracker.sql` once on the new project. It creates the tables, access policies, constraints, and audit triggers. Test on a new project first; this migration is not an upgrade for another application.

Authentication settings:

- Turn **Allow new users to sign up** off.
- Enable Email authentication and magic-link sign-in.
- Set Site URL to `https://mission-dg.github.io/DG-Mission-Meetings/`.
- Add exactly that URL to allowed redirect URLs. For local development, also allow `http://localhost:5173/` and `http://127.0.0.1:5173/`.
- Configure production email delivery before inviting your manager team. Supabase's built-in test email delivery has recipient/rate restrictions.

The site requests sign-in links with `shouldCreateUser: false`; disabling signups on the server is also required. Managers do not enter passwords on the GitHub Pages website.

## 2. Approve your first manager

Create your own account using the Supabase Authentication dashboard. Copy its user UUID. In SQL Editor, run this after substituting the real UUID and display name:

```sql
insert into public.manager_profiles (id, name, active, is_gm, is_admin)
values ('YOUR-AUTH-USER-UUID', 'Your display name', true, true, true);
```

There must be exactly one active GM. `is_admin` controls staff administration, not permission to edit someone else's meetings or notes.

For another manager, create/invite their Auth account and insert their UUID with `is_gm=false` and `is_admin=false`. All active managers can read meetings and notes. Only each record's creator can edit it. A manager can add their own note to someone else's meeting. The GM can link bookings to another manager's GM request but cannot withdraw it or edit their meetings/notes. Inactive/unapproved accounts cannot read or write application data.

Deactivate an account by setting its manager profile `active=false`; retain the profile and records. Transfer GM in a transaction that clears the old tag and assigns the new one. Account management remains in Supabase for this first version.

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
5. Open the URL reported by that workflow. Expected address: `https://mission-dg.github.io/DG-Mission-Meetings/`.

The expected address is not proof of deployment. The workflow's successful deployment is the authoritative result. Until Supabase variables are supplied and the site is rebuilt, it shows the setup screen.

## Local development and verification

Requires Node 22.12+ or a supported newer version.

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

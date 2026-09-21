# Username accounts for Shift

Status: implemented and locally tested; live installation and publication pending.

## Create a login — no email

Open **IT View → Accounts & access**, or **Manager View → Employee accounts** as GM.

1. Choose an existing active teammate.
2. Choose **Employee** or **Manager**.
3. Enter a username and click **Create account**.
4. Share the displayed username and generated temporary password privately.
5. The person signs in and sets their private password within seven days. No workspace data is accessible before that step.

Usernames ignore capitalization. They accept 3–32 letters, numbers, dots, underscores or hyphens. Existing employee IDs, meeting history and training stay unchanged. Manager accounts receive manager access after activation; creation does not grant GM or IT access. Existing role-management controls continue to handle those permissions.

## Change a username or reset a password

GM and IT can use **Change username / reset password** on a username account, including an account that has already been used. Keep the username unchanged to reset only the password. The replacement temporary password is displayed once and must be changed at the next sign-in. Passwords cannot be viewed or recovered. The action preserves records and roles, revokes calendar links, and invalidates prior sessions. Disabled accounts must be deliberately reactivated first.

To avoid accidentally locking yourself out, use **Change password** for your own password; another GM/IT must change your username. Old usernames remain reserved and cannot be assigned to another person.

An account left at **Setup needs IT review** after an uncertain provisioning failure cannot be blindly retried. An administrator must reconcile the Auth user and the pending operation before issuing credentials, so late requests cannot overwrite a newer password.

Existing email/password accounts continue to work. This release does not convert those accounts to usernames automatically. Username accounts use a reserved internal Auth identity under `users.shift.invalid`, not an employee email address. Optional email delivery is entirely separate from username creation and reset.

## Installation

1. Capture a fresh protected backup using `supabase/maintenance/backup_before_usernames.sql`.
2. If migration 016 has not been installed, apply `016_username_accounts.sql`; then apply `017_account_credentials.sql`. Apply each once. Do not rerun the tracker/workspace installer.
3. Deploy `supabase/functions/manage-accounts/index.ts` to the existing function, preserving server settings and secrets.
4. Publish the frontend from the development branch to `/shift/`.
5. Verify a designated test employee and manager through creation, password change, sign-in, reset and rename. The person testing must enter their private password themselves.

Installation creates no accounts and changes no existing roles. Auth administration uses the server-side service credential only. Passwords are not copied into application records, metadata or audit logs. The private temporary Auth-hash marker is cleared on activation. Pending setup and reset accounts are blocked from application data by database permission helpers, including direct API calls. Activated username access checks the actual Auth session against the latest credential operation; refreshed old tokens cannot restore access.

Supabase’s supported admin password update invalidates Auth sessions; Shift additionally checks session records for application access. Reference: [Supabase session guidance](https://supabase.com/docs/guides/auth/sessions).

## Validation

- All 44 automated test groups pass, including database permission, manager activation, active-account reset, old-session denial, stable identity/roles, username reservation, duplicate submissions and account-service failures.
- Production build passes.
- Browser preview shows Employee/Manager selection and account-editing controls without an email field or invitation prerequisite.
- Hosted lifecycle verification remains a rollout step; local tests do not substitute for testing a real Supabase login.

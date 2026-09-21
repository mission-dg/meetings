# Username accounts for Shift

Status: implemented and locally tested; production installation and publication pending.

## Daily use

IT: Accounts & access → Username accounts. GM: Manager View → Employee accounts → Username accounts.

1. Select an existing active employee and choose a username (3–32 letters, numbers, dots, underscores or hyphens).
2. Create the account. Shift generates a random temporary password and displays it once. Share the username and password privately; no email is sent.
3. The employee signs in using that username and temporary password. They must choose their own password within seven days before any workspace records are available.
4. Accounts start with employee access. IT can change roles using existing controls after activation.

A username ignores capitalization and is permanently reserved. Staff identity, meetings and training history are unchanged. IT and GM may reissue an unactivated temporary password from the account list. This invalidates the preceding temporary password. Interrupted provisioning can be retried after two minutes using the same username. Never create a second employee record as a workaround.

Existing email/password accounts continue to work. Email invitations remain separately gated by delivery verification. Username accounts use a reserved internal authentication address under `users.shift.invalid`; this is not an employee email and receives no mail.

This change adds account creation and reissuing **unactivated** temporary credentials. It does not convert existing email accounts or add self-service recovery for activated username accounts. Recovery for an activated account still needs administrator assistance through Supabase; do not create a duplicate account or staff record.

## Installation order

1. Take a fresh protected backup using `supabase/maintenance/backup_before_usernames.sql`.
2. Apply only `supabase/migrations/016_username_accounts.sql` to the existing project. Do not rerun the original tracker/workspace bundles.
3. Deploy the updated `supabase/functions/manage-accounts/index.ts` through the existing server function; preserve its environment and authentication settings.
4. Publish the frontend from the development branch to `/shift/`.
5. Exercise a designated test employee account: creation by IT/GM, initial sign-in, required password change, employee-only workspace, subsequent username sign-in, duplicate rejection and expired-password reissue. The person performing the check must enter their own permanent password.

The database migration creates no Auth users, changes no roles and leaves existing records intact. Pending username users receive no employee/manager membership until activation verifies an actual Auth password-hash change, an unexpired setup window, active employee status and the provisioning administrator's continued eligibility. Direct API calls enforce the same restrictions. Passwords never enter application records, metadata or audit logs; a private temporary Auth-hash marker is discarded on activation.

## Validation

- All 41 automated test groups pass, including real database permission/activation tests and mocked account-service failure/retry cases.
- Production build passes.
- Local account form is visible, accepts a case-insensitive username and refuses to create real credentials in disconnected demo mode.
- A hosted Supabase username-account lifecycle has not yet been exercised. Installation does not itself enable production rollout to employees.

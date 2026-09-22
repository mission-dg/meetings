# STARS Scheduling: phone access and store expansion

## This update

The public website remains at `/shift/`. Its name is STARS Scheduling, with the requested tagline “Scheduling Our Spectacular Teammates Achieving Remarkable Significance”. The tagline is user-supplied; official corporate wording has not been independently confirmed.

An installable web manifest, iOS/Android icons, installation help and a network-only service worker support home-screen installation. No app-store accounts are needed. The worker does not cache staff records, API responses, documents or schedules. An offline launch shows a reconnect page. Authentication persistence and existing browser view preferences continue unchanged. No background notifications or queued offline writes are introduced.

iOS: Safari → Share → Add to Home Screen; keep Open as Web App enabled if offered.
Android: Chrome → menu → Install app / Add to Home screen. A direct installation button also appears when the browser offers it.

Build with the existing GitHub Actions configuration for `/shift/`. Verify installation on a physical iPhone and Android phone after publication, including sign-in, launch, sign-out, reconnect and a version update. Desktop browser checks cannot substitute for device installation checks.

## Current data ownership

All existing operational records and test records belong to Downers Grove, Illinois (America/Chicago). Preserve their permanent IDs. Do not seed the other stores with those employees or test records. Public state/store directory research is a reference, not an authorization list or a list of verified open stores.

## Multi-store design for the next database upgrade

Use one Supabase backend with logically isolated store records. A separate physical database per restaurant is unnecessary for this model. Introduce stores with stable IDs, state, display name, timezone and activation status. Use the public reference list to prepare store onboarding; only activate a store explicitly.

Use account-to-store memberships and store-specific roles. Each GM and manager sees only authorized stores, with a remembered store selector and a separate scheduling context. Employees may belong to multiple stores while keeping one identity. Explicit platform IT access spans stores and is audited. Store GM privileges must never imply platform IT privileges.

Add store ownership to schedules and revisions, requests, jobs/qualifications as appropriate, meetings, training, announcements, documents, rates, forecasts and audit entries. Backfill existing records to Downers Grove in a backed-up transaction. Retain person-wide time off and check overlapping assignments across locations without exposing another store’s private details. Evaluate local recurring availability and calendar dates in each store’s timezone.

Enforce store membership in every SQL policy, security-definer function, download, export, account-management operation, calendar feed and release-worker transaction. Validate linked records belong to the same authorized store. Scope submission IDs, version checks and release locks to store/week. Clear cached view data and check unsaved forms on store changes. A URL/store dropdown alone provides no isolation.

Before enabling a second store, test two GMs, two employees and platform IT using direct API requests: cross-store reads/writes denied, guessed IDs denied, document and calendar isolation, store-scoped imports, release notifications, permission revocation, and retained Downers Grove IDs and history. Back up and test on a separate environment before rollout.

## Handoff to corporate owners or IT

Prepare repository ownership, Supabase ownership/billing, hosting and domain ownership, authentication provider configuration, access inventory, backup/restore instructions, migrations, deployment instructions and an operations runbook. Never put private records or credentials in GitHub. Give corporate administrators access explicitly; do not derive access from public store names.

Multi-store isolation is planned, not enabled by this branding/mobile update. No database records or permissions are changed in this release.

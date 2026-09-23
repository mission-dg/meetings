# Leadership titles and inherited qualifications

## Behavior

An active GM designation takes precedence over an active sSHL sign-off. Linked roster records use that title as their primary job. Ordinary jobs remain available for individual shifts. The previous operational primary is retained while leadership is active; removal restores it only when still active and individually qualified.

Operational eligibility is derived by the server for active FOH, HOH and Catering jobs, including jobs added later. No training sessions or individual sign-offs are generated. Trainer designations and account permissions are unchanged. Office eligibility retains the existing scheduling classification checks.

`qualifications_read()` returns permitted actual sign-offs plus read-only inherited entries with `origin: leadership` and `inherited_source: GM | sSHL`. Inherited entry IDs are opaque strings, version 0, and have no invented author or completion date. They are not mutation targets. Existing employee projections continue to filter qualifications to their permitted scope.

Primary-title enforcement covers profile writes and imports. Explicitly imported earned jobs create independent sign-offs even when currently covered by leadership. Revoking leadership preserves those sign-offs and sends managers a future-assignment review alert when necessary; existing schedules are not silently altered.

## Release procedure

1. Run `supabase/maintenance/backup_before_leadership.sql` as owner. Verify the returned backup ID and timestamp; do not export its private records.
2. Apply `supabase/migrations/036_leadership_qualifications.sql` transactionally. It reconciles existing leaders and reloads the API schema cache.
3. Verify metadata, title reconciliation, inherited sources and API restrictions before publishing the compatible interface. Do not modify real staff as a test.
4. Publish only this change's source, migration, maintenance script, tests and this document using the authorized GitHub account. Preserve unrelated changes.
5. Verify directory/profile titles, qualification filters, scheduling candidates, training displays and employee-safe views. Inspect deployment status and live asset version.

## Validation

The full local test suite and production build pass. Database integration tests use fictional records and cover title precedence, restoration, new/archived operational jobs, independent imports, candidate eligibility, future review alerts, GM protection and permission boundaries. Existing scheduling, meeting, release, account and training tests remain passing.

## Release status

Production backup `before-leadership-036-20260923020810294853` was captured at `2026-09-23 02:08:10.283973+00`. Migration 036 was installed after explicit approval. Production checks returned zero title mismatches, unchanged training-session and individual-signoff counts, and no anonymous qualification-read access. The matching interface was committed by mission-stars; publication is tracked through GitHub Pages deployment checks. Local validation: 106 tests passed and the production build passed.

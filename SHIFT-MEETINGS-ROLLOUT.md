# Shift cards and check-ins upgrade

Prepared September 21, 2026. Requires database migrations 001–023.

## Install
1. Capture `supabase/maintenance/backup_before_shift_meetings.sql` in the existing Supabase project. Verify its record counts before proceeding.
2. Apply `supabase/migrations/024_shift_meetings.sql` once. The migration is transactional and preserves legacy meeting IDs and timestamps.
3. Publish the matching frontend. Do not use the new Training category before migration 024 is installed.
4. In Manager → Schedule builder, create a draft, add a dedicated Training assignment, and review the separate hours. Choose Shift check-ins to select overlapping employee and manager work shifts.
5. Verify personal published annotations using a linked employee account; team members must not receive another employee’s meeting annotation.

## Validation
63 automated tests and the production build pass. Tests cover draft privacy, creator permissions, repeat submissions, stale revisions, routine duplicates, linked-shift protection, queued locks, completion, legacy linking, and overnight manager coverage across a Sunday boundary. Existing scheduling, qualifications, and account tests remain passing.

The disconnected browser preview verifies personal job/activity titles, seven-day desktop layout, manager-only Lunch/Dinner, daily and weekly hours, Training labels, Add shift placement, and 11 AM–4 PM defaults. Hosted rollout verification remains pending.

## Recovery
Keep the protected database snapshot `before-shift-meetings-024-20260921`. If rollout fails, stop publication and inspect the transaction error. After any new Training assignments or shift check-ins exist, do not restore an older frontend/database blindly: reconcile newer records first. Existing standalone meeting timestamps remain preserved, and converted legacy calendar events receive cancellation entries while the work shift carries the annotation.

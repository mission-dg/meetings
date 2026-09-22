# Hours, coverage, and shift-change rollout

Status: implemented and locally tested; production installation and publication pending.

## Coordinated installation

1. Push the reviewed `codex/staff-scheduler` commit. Keep the current site authoritative until the compatible build is ready.
2. Run `supabase/maintenance/backup_before_planning.sql` in the existing Supabase project and verify the backup row before migration. The backup stays in Supabase; do not download employee records into the repository.
3. Apply migrations through 028, then 029_planning_reviews.sql in a separate test project. Verify manager, GM/IT, and employee accounts there.
4. Deploy migration 029 and its matching frontend together during a controlled pilot update. The old frontend cannot supply the new release acknowledgment. Existing queued releases become Needs attention and must be reviewed again. Published schedules remain intact.
5. GM/IT configure real weekday service windows, sales bands, required job counts, and Lunch percentages. No operational rules are fabricated. Missing setup requires explicit manager acknowledgment at release.
6. Verify a small draft, forecast, queued release, and each shift-change flow with test accounts before pilot use. Schedulefly remains authoritative.

## Validation completed

79 automated tests pass, including PostgreSQL-compatible database tests for migration 029, 35/40-hour boundaries, Sunday clipping, daylight-saving elapsed duration, coverage bands and overrides, missing configuration, queued-release invalidation, repeat submissions, stale trade reviews, competing claims, and restricted API access. Existing regressions also pass. Production build passes; it retains a non-blocking bundle-size warning.

The local manager preview was checked for staffing controls and the release acknowledgment form. Physical iOS/Android and live Supabase account testing remain rollout checks. Preview mode does not write operational records.

## Interpretation

Scheduled hours are planning estimates, not payroll or legally payable overtime. Training blocks count toward scheduled hours but not position coverage; position coaching remains regular work. Salaried staff are excluded from hourly estimates but count when assigned actual position coverage. Coverage uses exact shift intervals, independently of card Lunch/Dinner grouping.

All configuration, forecasts, review acknowledgments, and audit records are private Supabase data. GitHub contains application code, additive migrations, and fictional tests only. Multi-location isolation is a separate upgrade.

## Staff meetings and 1:1s (migration 032)

Apply 030–032 with the matching interface after the Supabase backup. Staff meetings use the existing private schedule draft and Training assignments, including release reviews, hours calculations, coverage, calendars, and release notifications. During-shift meetings split regular work intervals; cancellation restores them in the draft. Only the creator can cancel/replan a group. Published schedules stay unchanged until release. Replanning is cancellation followed by a new meeting; attendees are an explicit snapshot, not a changing live membership list. Linked coaching and 1:1s must be replanned before splitting their work shifts. Group meetings never create qualification sessions or complete 1:1s. Existing meeting records are displayed as 1:1s without changing their IDs or history.

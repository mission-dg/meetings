# Workflow helpers and onboarding release

Status: migration 035 installed in production Supabase on September 22, 2026. Frontend published in commit b51ddff5aceaa2614c5c7e6199da697089e20414; GitHub Pages run 35803563190 succeeded. Live assets verified for tutorials, combined requests/availability, attendee builder, staff-meeting visibility and daily staffing print layout.

Installation backup: `before-workflow-035-20260922205330223372`, captured `2026-09-22 20:53:30.079907+00`, retained privately in Supabase. Installation committed successfully and the API schema was reloaded. An anonymous API request resolves assignment_candidates and is denied with 42501 (rather than missing-function PGRST202). All three new tables have RLS enabled and no direct authenticated table access. No schedules or employee records were changed.

## Delivered

- Authorized Create menu reuses existing shift, training, staff-meeting, 1:1, announcement and employee forms. Missing draft prerequisites are explicit.
- Optional four-step schedule checklist alongside the existing board.
- Shared shift presets with version checks, retry protection and archive confirmation. Presets fill editable fields; they never save a shift automatically.
- Searchable shift, training and check-in selectors with eligibility context. Shift candidates have authoritative server conflict/hour assessments; existing save and release validation remains in force.
- Overview links to the selected week, training and 1:1 follow-ups. Missing assessment data remains unavailable.
- Optional first-visit tours for Employee, Manager and IT, plus a CA chapter. IT reuses Manager essentials. Help supports resume and restart. Tour navigation replaces temporary history entries and restores the originating URL, directory filters, sidebar groups and scroll.
- Fictional Manager, Employee and IT practice exercises. Operational Supabase traffic is blocked while practice is active; only authentication and own onboarding progress are allowed.
- Own-account, versioned progress stored in Supabase, with explicit failure messages. No employee data or private presets are included in hosted assets.

## Existing workflows retained

Schedule board/release, approvals, availability, qualifications, training, staff meetings, private 1:1s, accounts, CSV workflows and employee navigation remain on their existing validated paths. SHL office eligibility, salaried sSHL meeting hosts, creator-only editing, GM/IT distinctions and Schedulefly pilot authority are unchanged.

## Validation

Production build passed. All 100 regression tests passed, including new embedded-Postgres permission, own-progress, preset stale/retry/archive, assignment-candidate and practice isolation tests. Browser checks earlier in this task exercised Create draft prerequisites, preset filling, searchable people, manager tour entry, and the Manager practice conflict/review/release scenario.

Final interactive verification remains pending: full tour finish/restore and Back behavior, Employee/IT practice via the UI, keyboard focus restoration and phone dialogs. The browser began returning unchanged pages or interaction timeouts; these are not recorded as passed.

## Deployment sequence

1. Complete the pending UI checks with fictional preview records. Never use real shifts/accounts for practice tests.
2. Take an owner-only recoverable snapshot in private.scheduler_backups using the existing backup_before_planning.sql pattern with a before-workflow-035 prefix. Keep records in Supabase.
3. Apply 035_workflow_onboarding.sql after 034 in a transaction. It is additive and leaves existing scheduling authorization unchanged. Verify anonymous denial, own-progress access and manager-only presets/candidates.
4. Publish compatible source via mission-stars/shift using the user-authorized Mission STARS GitHub account. Do not upload environment files, backups or unrelated icon deletions.
5. Confirm the Pages deployment succeeds, then verify live first-visit offers, own progress after refresh, preset save/edit/archive, candidate assessment and existing release/approval flows. Do not publish a real schedule as a smoke test.
6. If the frontend must roll back, restore the previous frontend; the additive private tables may remain. Do not remove operational data to roll back.

## Boundaries

Practice covers the agreed core exercises only; it is not a clone of all administration tools. It does not create credentials, send email, grant roles or publish real schedules. Presets are individual shift patterns, not full-week templates. Coverage rules remain unconfigured until entered by authorized staff.

## Follow-up interface changes in this release

- Requests & availability is one destination; current accepted availability stays visible, with Pending, Approved and All requests / history sections.
- Meeting attendees can be assembled from multiple groups and individual people without duplicate entries. Browser smoke check verified a trainer group plus an individual produced two attendees.
- Published personal staff meetings remain visible on the schedule across position filters, with the Training assignment labelled instead of duplicating it when visible.
- Daily print contains only scheduled names, jobs and times. Hours breakdowns are management-only.
- Manager/IT password changes live in Settings → My account; the duplicate sidebar dropdown is removed.

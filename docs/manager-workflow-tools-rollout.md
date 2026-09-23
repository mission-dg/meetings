# Manager workflow improvements — migration 038

Delivered in requested order:
1. Account-scoped Favorites in the existing grouped management sidebar, with a compact star beside the current page title. Original links stay present; unauthorized links cannot be stored through the API.
2. Selective copying from an earlier published week into a new private draft. The source publication is checked, IDs regenerated, Central local times retained, daylight-saving ambiguities rejected, and training/meeting blocks omitted. Copy and draft save are one transaction, using the existing validation path.
3. Find coverage inside an existing shift editor, using authoritative candidate assessment, qualification warnings, availability/conflicts and projected hours. Selection does not save automatically. Linked activities must be replanned first.
4. Manager action list linking requests, release attention, overdue training and 1:1 reminders to their existing destinations. Coverage assessment remains separately explicit about unavailable results.
5. Bulk selection, time movement, reassignment and removal with before/after review, draft version checks, normal server validation and linked-activity exclusions.
6. Global unsaved/saving feedback alongside existing save results and failure preservation.
7. Release review now includes before/after identity, job, time and notes for changed assignments.
8. Creator-only attendance after a published staff meeting ends. Independent attendance versions, retries and audit history; no qualification, training completion, schedule-hour or 1:1 mutations. Employees receive no attendance roster.
9. Four replayable role-filtered Help tutorials covering week building, request decisions, staff meetings/attendance, and training completion. Existing first-use introductions and fictional practice remain available.

## Verification
112 tests passed locally, including direct API role/ownership checks, personal preference isolation, selective copy, stale source and attendance versions, duplicate submission replay, unchanged training history and Central-time bulk transformations. Disconnected browser checks cover pinning without removing original links, selective copy, bulk review/save, release summaries and tutorial navigation/return.

## Rollout
Run maintenance/backup_before_workflow_tools.sql privately in Supabase, then migrations/038_manager_workflow_tools.sql, then deploy compatible interface files. Do not expose or download backup records. Do not generate pilot employee records for testing. Schedulefly remains authoritative during the pilot.

Backup completed: before-workflow-038-20260923033104034466. Migration 038 installed successfully.

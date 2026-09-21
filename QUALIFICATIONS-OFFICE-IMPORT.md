# Qualifications, management shifts, and employee migration

## Daily use

- Meetings & staff → Staff directory → Edit: choose a primary job and view qualifications across FOH, HOH, and Catering. Managers can schedule training or confirm readiness after the target. GM/IT can qualify prior experience or revoke qualification with a reason.
- Accounts → SHL schedule category: GM/IT classify managers as Hourly or Salaried. Unclassified managers retain their prior visibility. Classification does not grant permissions or change pay rates.
- Schedule builder: SHLs can have a regular job or general SHL duty, Opening office, or Closing office. Office blocks are separate, non-overlapping assignments. Salaried work and all office blocks appear in Management & office. Hourly office time counts only once.
- Meetings & staff → IT Admin → Import employees: upload CSV, choose one wage effective date, confirm existing-person matches, review before/after values, and apply the batch. No rows are saved if any validation or stale-review check fails.

Template:
```csv
Staff ID,First Name,Last Name,Position,Active,Primary Role,Other Roles,Hourly Wage
,Alex,Example,FOH,Yes,GSR,"EXPO, DRL, Catering",17.50
```

Primary Role and Other Roles become earned qualifications; training sessions are not fabricated. Existing employees keep names, identities, active status, and access. Blank cells do not clear rates or qualifications. Same-date wage replacements are explicitly shown. Use Group: Job if job names are ambiguous. New employees require a primary job.

## Rollout

1. Capture `supabase/maintenance/backup_before_qualifications.sql` before upgrading. It includes pay rates and pre-upgrade function definitions/policies in a protected recovery snapshot.
2. Apply migrations 021 and 022 once, in order, in one transaction.
3. Publish the matching frontend. Sign-off mutations now use the audited RPC, so do not leave the old frontend as the supported client.
4. Check the new forms, office section, and an import preview without saving production test records.
5. Before a real migration, review a small batch and its matches/rates with the owner. The test suite exercises actual import transactions in an isolated database.

No classification or qualification is inferred for existing employees. A rollback after live activity needs reconciliation; do not restore the snapshot wholesale over newer records. Keep migrations and backup as the recovery reference and prefer a corrective forward migration.

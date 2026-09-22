# Connected management workspace

This interface update reuses existing Supabase tables, RLS, scheduling RPCs, account services and qualification controls. It requires no new migration. Deploy only on top of the pending compatible scheduling/qualification/staff-meeting/location changes documented in planning-rollout.md.

Changes include shared grouped navigation, actionable staff directory, profile panels/full profile sections, direct Staff meetings and 1:1 pages, separate Teammate/SHL account tabs, Settings editors and searchable Help. IT no longer needs Manager View to access scheduling. Employee navigation remains separate.

Profile history is loaded through existing RLS-protected queries filtered to the selected staff ID; directory loads do not request private meeting notes. Generic help content is bundled, but no operational data is bundled. Existing creator-only mutation and GM/IT restrictions remain enforced by the server.

Before pilot publication:
- Push the reviewed branch using the owner's established workflow.
- Confirm prerequisite migrations/functions and backups from planning-rollout.md.
- Verify IT and manager login, account group tabs, employee editing, profile navigation, training settings, staffing configuration, 1:1 completion, release, approvals, CSV and employee privacy against the connected pilot.
- Keep Schedulefly authoritative. No employee records are changed by installing this interface.

Validation in the isolated local environment: build, full Node/PGlite regression suite, role/navigation/account-group checks, and browser checks of profile, Settings and Help navigation. No production employee data was edited for validation.

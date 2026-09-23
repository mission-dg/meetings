# Personal appearance and schedule legend — migration 037

Each authenticated active user owns their Light/Dark/Follow device mode, named palette and optional job/type overrides. Settings → My account → Your appearance; employees reach Settings through More. Other accounts are never changed. Default mode is Light, preserving tan/orange branding. No administrative appearance-write endpoint exists.

`appearance_read()` returns the caller's version/mode/palette/overrides and the non-sensitive stable default color catalog. `appearance_save(version,mode,palette,overrides,submission)` validates keys and named presets, rejects stale writes, locks per account, and deduplicates retries. Private tables have no client grants. Defaults are inserted once for existing/new jobs and retained when renamed/archived. If more jobs exist than presets, least-used colors are reused and the editor identifies duplicates.

`workspace_read` preserves the previous permission projection, then adds `schedule_meeting_shifts` for generated training assignments already visible in that projection. It exposes no new titles, attendees, or private notes. Original shift JSON remains unchanged, preserving staff-meeting cancellation comparisons. Colors reflect assigned jobs; embedded training/check-ins remain badges. Legends sit outside schedule grid scrolling and show the filtered jobs plus an expandable complete key.

Run the private `backup_before_colors.sql` snapshot before installing migration 037. Keep the snapshot within Supabase; report metadata only. Install migration and compatible UI, then verify live schema, account isolation and Pages build. Rollback UI to previous commit if needed; additive tables may remain safely. No employee or training history is changed.

Validation: SQL fixtures cover employee isolation, inactive/anonymous denial, stale writes, idempotent retries, invalid keys/presets, new/archived/renamed jobs and private draft meeting visibility. Contrast tests cover all preset text/borders in light and dark. Verify keyboard unsaved-edit protection, mobile layout, employee Settings, theme change on saved preference, and monochrome printing. All SQL tests use fictional data.

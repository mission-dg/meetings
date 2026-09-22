import type {SchedulerData, WorkShift} from './scheduler';

// Meetings use stable shift IDs across releases. The originating revision may
// no longer be the current publication, so it is not a display eligibility test.
export function shiftMeetingNotes(data: SchedulerData, shift: WorkShift) {
 const manager = data.self.is_manager;
 if (!manager && (shift.person_id !== data.self.person_id || !data.published.some(p => p.shifts.some(s => s.id === shift.id)))) return [];
 return (data.shift_meetings || []).filter(m => {
  if (m.timing_mode !== 'during_shift' || !['Scheduled', 'Completed'].includes(m.status)) return false;
  if (m.work_shift_id !== shift.id && !(manager && m.manager_shift_id === shift.id)) return false;
  if (!manager && shift.person_id !== 's:' + m.staff_id) return false;
  if (m.schedule_revision_id === data.week.draft?.id && (!manager || !data.week.draft.shifts.includes(shift))) return false;
  return true;
 }).map(m => ({id:m.id, status:m.status, text:`${m.status === 'Completed' ? '✓ 1:1 completed' : '1:1 scheduled'} with ${m.work_shift_id === shift.id ? m.manager : m.employee} during this shift`}));
}

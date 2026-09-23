export type ScheduleStaffMeeting={id:string;title:string;start:string;end:string;status:string;mode:string};
export function publishedStaffMeetings(meetings:ScheduleStaffMeeting[]){return meetings.filter(m=>m.status==='Published').sort((a,b)=>a.start.localeCompare(b.start));}

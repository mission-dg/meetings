import type {ScheduleRequest,SchedulerData} from './scheduler';
export function notificationRequestId(key?:string):string|null {
 const match=/^(?:request|accepted|decision|revoke|invalid):([^:]+)$/.exec(key||'');
 return match?.[1]||null;
}
export function canReviewRequest(q:ScheduleRequest,self:SchedulerData['self']):boolean {
 return self.is_manager&&q.created_by!==self.id&&q.claimed_by!==self.id&&
  ((['Availability','Time off','Cancel time off'].includes(q.kind)&&q.status==='Pending')||q.status==='Accepted');
}

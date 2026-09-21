import {useState} from 'react';
import type {Employee,Data} from './domain';
export function RemoveEmployeeFields({employee,data,busy,onClose}:{employee:Employee;data:Data;busy:boolean;onClose:()=>void}){
 const [phrase,setPhrase]=useState(''),[confirmation,setConfirmation]=useState('');
 const expected=`Remove ${employee.first_name} ${employee.last_name}`;
 const meetings=data.meetings.filter(m=>m.staff_id===employee.id&&m.status==='Scheduled').length;
 const training=data.training.filter(t=>(t.staff_id===employee.id||t.trainer_id===employee.id)&&t.status==='Scheduled').length;
 return <><p><strong>{employee.first_name} {employee.last_name}</strong> will be removed from the active roster and attention lists. Their ID, meetings, training, and notes will remain. You can restore them through Staff directory → All → Edit → Active employee.</p>{(meetings+training)>0&&<p className="error">There are {meetings} open meetings and {training} open training sessions involving this employee. These bookings will remain; their creators can cancel them separately.</p>}<label>Type “{expected}”<input name="removalPhrase" value={phrase} onChange={e=>setPhrase(e.target.value)} required autoComplete="off" spellCheck={false} disabled={busy}/></label><label>Then type “Confirm”<input name="removalConfirm" value={confirmation} onChange={e=>setConfirmation(e.target.value)} required autoComplete="off" spellCheck={false} disabled={busy}/></label><div className="modal-footer"><button type="button" disabled={busy} onClick={onClose}>Cancel</button><button className="danger-button" disabled={busy||phrase!==expected||confirmation!=='Confirm'}>{busy?'Removing…':'Remove employee'}</button></div></>;
}

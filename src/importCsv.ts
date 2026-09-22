export type ImportRow={first_name:string;last_name:string;department:'FOH'|'BOH'|'Catering'|'SHL';active:boolean;staff_id?:string;primary_role?:string;other_roles?:string[];hourly_wage?:string;choice?:string;target_id?:string};
export function parseEmployees(text:string):ImportRow[]{
 if(text.length>1_000_000)throw Error('Choose a CSV smaller than 1 MB.');
 const rows:string[][]=[];let row:string[]=[],cell='',quoted=false,closed=false;
 text=text.replace(/^\uFEFF/,'');
 for(let i=0;i<text.length;i++){
  const c=text[i];
  if(quoted){if(c==='"'){if(text[i+1]==='"'){cell+='"';i++}else{quoted=false;closed=true}}else cell+=c;continue}
  if(c==='"'){if(cell||closed)throw Error('Unexpected quote in CSV. Export the file as CSV again.');quoted=true}
  else if(c===','||c==='\n'||c==='\r'){row.push(cell.trim());cell='';closed=false;if(c!==','){if(c==='\r'&&text[i+1]==='\n')i++;if(row.some(Boolean))rows.push(row);row=[]}}
  else {if(closed&&c.trim())throw Error('Unexpected text after a quoted field.');if(!closed)cell+=c}
 }
 if(quoted)throw Error('A quoted field is unfinished. Export the file as CSV again.');
 row.push(cell.trim());if(row.some(Boolean))rows.push(row);
 const headers=rows.shift()?.map(h=>h.toLowerCase().replace(/[ _-]/g,'').replace(/^position$/,'department'));
 const allowed=['firstname','lastname','department','active','staffid','primaryrole','otherroles','hourlywage'];
 if(!headers||new Set(headers).size!==headers.length||headers.some(h=>!allowed.includes(h))||!['firstname','lastname'].every(h=>headers.includes(h)))throw Error('Use the employee template column names; First Name and Last Name are required columns.');
 if(!rows.length||rows.length>500)throw Error('Include between 1 and 500 employees.');
 return rows.map((r,i)=>{const v=(h:string)=>r[headers.indexOf(h)]||'';const f=v('firstname'),l=v('lastname'),d=v('department').toUpperCase()==='CATERING'?'Catering':v('department').toUpperCase()==='HOH'?'BOH':v('department').toUpperCase(),a=v('active').toLowerCase();
  if(r.length!==headers.length||(!v('staffid')&&(!f||!l))||f.length>100||l.length>100||!['','FOH','BOH','Catering','SHL'].includes(d)||!['true','false','yes','no','1','0',''].includes(a))throw Error(`Row ${i+2}: enter both names, FOH, HOH, Catering, or SHL, and Yes/No for Active (blank means Yes).`);
  return {first_name:f,last_name:l,department:d as 'FOH'|'BOH'|'Catering'|'SHL',active:!['false','no','0'].includes(a),...(headers.includes('staffid')?{staff_id:v('staffid')}:{}),...(headers.includes('primaryrole')?{primary_role:v('primaryrole')}:{}),...(headers.includes('otherroles')?{other_roles:[...new Set(v('otherroles').split(',').map(x=>x.trim()).filter(Boolean))]}:{}),...(headers.includes('hourlywage')?{hourly_wage:v('hourlywage')}:{})};
 });
}
export const personKey=(p:{first_name:string;last_name:string})=>p.first_name.trim().toLowerCase()+'\u0000'+p.last_name.trim().toLowerCase();

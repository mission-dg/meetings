export type ImportRow={first_name:string;last_name:string;department:'FOH'|'BOH'|'Catering';active:boolean};
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
 if(!headers||headers.length!==4||new Set(headers).size!==4||!['firstname','lastname','department','active'].every(h=>headers.includes(h)))throw Error('Use the four template columns: First Name, Last Name, Position, Active.');
 if(!rows.length||rows.length>500)throw Error('Include between 1 and 500 employees.');
 return rows.map((r,i)=>{const v=(h:string)=>r[headers.indexOf(h)]||'';const f=v('firstname'),l=v('lastname'),d=v('department').toUpperCase()==='CATERING'?'Catering':v('department').toUpperCase()==='HOH'?'BOH':v('department').toUpperCase(),a=v('active').toLowerCase();
  if(r.length!==4||!f||!l||f.length>100||l.length>100||!['FOH','BOH','Catering'].includes(d)||!['true','false','yes','no','1','0',''].includes(a))throw Error(`Row ${i+2}: enter both names, FOH, HOH, or Catering (SHLs are added through SHL accounts), and Yes/No for Active (blank means Yes).`);
  return {first_name:f,last_name:l,department:d as 'FOH'|'BOH'|'Catering',active:!['false','no','0'].includes(a)};
 });
}
export const personKey=(p:{first_name:string;last_name:string})=>p.first_name.trim().toLowerCase()+'\u0000'+p.last_name.trim().toLowerCase();

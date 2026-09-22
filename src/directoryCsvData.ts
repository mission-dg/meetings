export type DirectoryRow={staff_id:string;revision:string;first_name:string;last_name:string;primary_job:string;earned_jobs:string[];trainer_roles:string[]};
export const directoryHeaders=['Staff ID','Revision','First Name','Last Name','Primary Job','Earned Jobs','Trainer Roles'];
export function directoryCells(rows:DirectoryRow[]):unknown[][]{return [directoryHeaders,...rows.map(r=>[r.staff_id,r.revision,r.first_name,r.last_name,r.primary_job,r.earned_jobs.join(', '),r.trainer_roles.join(', ')].map(s=>s.startsWith("'")?"'"+s:s))]}
export function parseDirectory(text:string):DirectoryRow[]{
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
 const headers=rows.shift();if(!headers||headers.length!==directoryHeaders.length||headers.some((h,i)=>h!==directoryHeaders[i]))throw Error('Use a fresh Directory CSV and keep the column headings and order unchanged.');
 if(!rows.length||rows.length>500)throw Error('Include 1–500 employee rows.');
 const ids=new Set<string>();
 return rows.map((cells,i)=>{if(cells.length!==headers.length)throw Error(`Row ${i+2}: check the number of columns and quote comma-separated roles.`);
 const [staff_id,revision,first_name,last_name,primary_job,earned,trainer]=cells.map(s=>/^'[=+@\-\t\r']/.test(s)?s.slice(1):s);
 if(!staff_id||!revision||!first_name||!last_name)throw Error(`Row ${i+2}: keep the Staff ID and Revision, and enter both names.`);
 if(ids.has(staff_id))throw Error(`Row ${i+2}: duplicate Staff ID.`);ids.add(staff_id);
 const list=(s:string)=>[...new Set(s.split(',').map(x=>x.trim()).filter(Boolean))];
 return {staff_id,revision,first_name,last_name,primary_job,earned_jobs:list(earned),trainer_roles:list(trainer)};
 });
}

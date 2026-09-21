import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const files=['009_scheduler','011_workspaces_requests','012_operations','013_document_storage','014_calendar_feed','015_employee_roles','010_scheduler_cron'];
const parts=[];
for(const name of files){const source=await readFile(new URL('../supabase/migrations/'+name+'.sql',import.meta.url),'utf8');parts.push('-- '+name+'\n'+source.split('\n').filter(line=>!['begin;','commit;'].includes(line.trim().toLowerCase())).join('\n'))}
const sql='-- Shift workspace upgrade for a database at migrations 001–008. Apply once.\n-- No live data is seeded. Preserve a fresh owner-controlled backup first.\nbegin;\n'+parts.join('\n\n-- Flush deferred validation before subsequent table changes, retaining atomic installation.\nset constraints all immediate;\nset constraints all deferred;\n\n')+'\ncommit;\n';
await writeFile(new URL('../supabase/INSTALL_WORKSPACES.sql',import.meta.url),sql);
const sha=createHash('sha256').update(sql).digest('hex');
await writeFile(new URL('../WORKSPACE-PACKAGE.sha256',import.meta.url),sha+'  supabase/INSTALL_WORKSPACES.sql\n');
process.stdout.write('Workspace SQL SHA-256: '+sha+'\n');

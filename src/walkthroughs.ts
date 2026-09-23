import type {SchedulerData,Workspace} from './scheduler';
export type TourStep={title:string;text:string;page:string;target:string};
export type Chapter={id:string;title:string;steps:TourStep[]};
export const chapters:Chapter[]=[
 {id:'employee',title:'Employee essentials',steps:[
 {title:'Your next shift',text:'Start here to see your next published assignment. Private drafts do not appear in Employee View.',page:'home',target:'page-content'},
 {title:'Your schedule',text:'Open an upcoming card to see work, training and 1:1 details. Eligible cards offer Trade shift, Ask coworker to cover and Offer shift. A coworker must accept before a manager approves.',page:'schedule',target:'page-content'},
 {title:'Requests and availability',text:'Use Requests for time off and shift changes. Existing approved restrictions remain until a replacement is approved. Never assume a submitted request is already approved.',page:'requests',target:'page-content'},
 {title:'Training and meetings',text:'More contains training, staff meetings, and your profile and calendar. Your own meeting details remain private.',page:'more',target:'employee-navigation'},
 {title:'Help whenever you need it',text:'Replay this walkthrough, try fictional practice, or follow the phone installation and private calendar instructions.',page:'help',target:'help-center'}]},
 {id:'manager',title:'Manager essentials',steps:[
 {title:'Daily work at a glance',text:'Attention cards open specific requests and weeks. Unavailable checks are not a healthy result.',page:'home',target:'page-content'},
 {title:'Create from one place',text:'Create opens your existing shift, training, meeting, announcement and authorized employee forms. Missing prerequisites are explained before you proceed.',page:'home',target:'create-menu'},
 {title:'Connected employee information',text:'Search the shared directory and open a person for jobs, training, schedule and authorized account actions. Matching names do not mean the same person.',page:'directory',target:'page-content'},
 {title:'Build this week',text:'The optional checklist walks through forecasts, assignments, issues and release. You can still work directly on the board. Shift presets fill a form; they never save automatically.',page:'schedule',target:'schedule-guide'},
 {title:'Review before release',text:'35–40 hours means Approaching OT; above 40 means Projected OT. Review all jobs and acknowledge hours, shortages or incomplete coverage setup with a reason. The server rechecks publication.',page:'schedule',target:'release-actions'},
 {title:'Approve with context',text:'Open a request to review the actual assignment changes, affected hours and coverage. Approve or deny explicitly; denial requires a reason.',page:'requests',target:'page-content'},
 {title:'Practice safely',text:'Help contains replayable chapters and an isolated fictional practice exercise. Practice never publishes real shifts.',page:'help',target:'help-center'}]},
 {id:'it',title:'IT administration',steps:[
 {title:'All manager tools in one workspace',text:'IT includes manager destinations without switching views. Complete Manager essentials as well if you have not already done so.',page:'home',target:'page-content'},
 {title:'Accounts and access',text:'Teammate accounts and SHL accounts are separate tabs. Keep roster status distinct from login status. Follow the existing confirmations for access changes and password resets.',page:'accounts',target:'page-content'},
 {title:'Configuration',text:'Settings contains working coverage, training and service controls. Use actual store rules; missing coverage setup never means targets are met.',page:'settings',target:'page-content'},
 {title:'Service checks and recovery',text:'Check the last successful release worker timestamp. Missing or stale information needs investigation. If a save succeeded but refresh failed, refresh rather than resubmitting.',page:'settings',target:'page-content'},
 {title:'Help and account practice',text:'Try creating a fictional teammate and simulated account in practice. No credentials or notifications are generated.',page:'help',target:'help-center'}]},
 {id:'ca',title:'Community Ambassador tools',steps:[{title:'Your authorized tools',text:'Your CA tools provide the training and announcement actions allowed by your account. They do not automatically grant scheduling management.',page:'home',target:'page-content'},{title:'Training prerequisites',text:'Position training requires eligible trainee and trainer work shifts and the correct job. Dedicated Training blocks do not automatically grant a qualification.',page:'training',target:'page-content'},{title:'Team announcements',text:'Review the audience and message before publishing. This walkthrough never submits a message.',page:'announcements',target:'page-content'}]}
];
export function availableChapters(data:SchedulerData,workspace:Workspace){return chapters.filter(c=>workspace==='employee'?c.id==='employee'||c.id==='ca'&&data.self.is_ca:c.id==='manager'&&data.self.is_manager||c.id==='it'&&data.self.is_admin)}

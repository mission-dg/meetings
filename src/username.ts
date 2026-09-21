// Reserved internal Auth identity; no mailbox or email delivery is used.
export function loginIdentity(value:string){
 const input=value.trim().toLowerCase();
 if(input.includes('@'))return input;
 if(!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(input))throw Error('Enter your username or email address.');
 return input+'@users.shift.invalid';
}
export type UsernameStatus={required:boolean;username?:string;ready?:boolean;expires_at?:string};

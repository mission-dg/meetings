import type {InputHTMLAttributes} from 'react';

export function currencyValue(value:string,max=999999999.99){
 const text=value.trim();
 if(!/^(?:(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{0,2})?|\.\d{1,2})$/.test(text))return null;
 const number=Number(text.replaceAll(',',''));
 return Number.isFinite(number)&&number>=0&&number<=max?number:null;
}
export function CurrencyInput(props:Omit<InputHTMLAttributes<HTMLInputElement>,'type'|'onChange'|'onBlur'>){
 function validate(input:HTMLInputElement){
  const value=currencyValue(input.value);
  input.setCustomValidity(input.value.trim()&&value===null?'Enter an amount from 0 to 999,999,999.99 with up to two decimal places. Commas must separate groups of three digits.':'');
  return value;
 }
 return <input {...props} type="text" inputMode="decimal" onChange={e=>{validate(e.currentTarget)}} onBlur={e=>{
  const input=e.currentTarget,value=validate(input);
  if(value!==null){const decimals=input.value.trim().split('.')[1]?.length||0;input.value=value.toLocaleString('en-US',{minimumFractionDigits:decimals,maximumFractionDigits:2})}
 }}/>;
}

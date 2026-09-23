import {useEffect} from 'react';
import type {Appearance} from './scheduleColors';
export function useAppearanceTheme(mode:Appearance['mode']|undefined,userId:string|undefined){useEffect(()=>{const media=window.matchMedia('(prefers-color-scheme: dark)');const apply=()=>{document.documentElement.dataset.theme=userId&&(mode==='dark'||mode==='system'&&media.matches)?'dark':'light'};apply();media.addEventListener('change',apply);return()=>{media.removeEventListener('change',apply);delete document.documentElement.dataset.theme}},[mode,userId]);}

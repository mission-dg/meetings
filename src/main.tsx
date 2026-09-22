import React from 'react';
import {createRoot} from 'react-dom/client';
import './pwa';
import './style.css';
import {WorkspaceRoot} from './WorkspaceRoot';
createRoot(document.getElementById('root')!).render(<React.StrictMode><WorkspaceRoot/></React.StrictMode>);

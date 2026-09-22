import React from 'react';
import {createRoot} from 'react-dom/client';
import './pwa';
import './style.css';
import {WorkspaceRoot} from './WorkspaceRoot';
import './brand.css';
createRoot(document.getElementById('root')!).render(<React.StrictMode><WorkspaceRoot/></React.StrictMode>);

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import DoryExperience from './DoryExperience'
import './DoryExperience.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <DoryExperience />
  </StrictMode>,
)

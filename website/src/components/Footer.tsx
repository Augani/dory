import { FishIcon } from './FishIcon'

export function Footer() {
  return (
    <footer>
      <div className="wrap">
        <div className="foot">
          <a className="brand" href="#top" style={{ fontSize: 15 }}>
            <span className="tile" style={{ width: 26, height: 26, borderRadius: 7 }}>
              <FishIcon style={{ width: 22, height: 22 }} />
            </span>
            Dory
          </a>
          <div className="links">
            <a href="https://github.com/Augani/dory" target="_blank" rel="noopener">
              GitHub
            </a>
            <a href="https://github.com/Augani/dory/releases" target="_blank" rel="noopener">
              Releases
            </a>
            <a href="https://github.com/Augani/dory/blob/main/COMPATIBILITY.md" target="_blank" rel="noopener">
              Compatibility
            </a>
            <a href="https://github.com/Augani/dory/blob/main/LICENSE" target="_blank" rel="noopener">
              License
            </a>
          </div>
        </div>
        <p className="fine">
          Made for Apple Silicon Macs · GPL-3.0 · © 2026 Dory contributors. Not affiliated
          with Docker, Inc. or OrbStack.
        </p>
      </div>
    </footer>
  )
}

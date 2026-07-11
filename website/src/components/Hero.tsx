import { useState } from 'react'
import { DoryFish } from './DoryFish'

const BREW_CMD = 'brew install --cask Augani/dory/dory'

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      onClick={() => {
        navigator.clipboard.writeText(text).then(() => {
          setCopied(true)
          setTimeout(() => setCopied(false), 1400)
        })
      }}
    >
      {copied ? 'Copied!' : 'Copy'}
    </button>
  )
}

export function Hero() {
  return (
    <section className="hero-section" id="top">
      <div className="wrap">
        <DoryFish />
        <div className="pill">
          <span className="dot" /> Free &amp; open source · Intel + Apple silicon
        </div>
        <h1>
          Docker &amp; Linux containers, <span className="grad">native to your Mac.</span>
        </h1>
        <p className="sub">
          One shared Linux VM for every container. A real Docker socket your CLI already speaks.
          HTTPS domains, one-click Kubernetes, and full Linux machines in a native app that's free
          and open source. Use the full clean-Mac bundle, or the ~6&nbsp;MB lite app with an engine
          you already run.
        </p>
        <div className="cta-row">
          <a
            className="btn btn-primary btn-big"
            href="https://github.com/Augani/dory/releases/latest"
            target="_blank"
            rel="noopener"
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
              <path d="M8 12 3 7l1.4-1.4L7 8.2V0h2v8.2l2.6-2.6L13 7l-5 5Zm-6 4v-4h2v2h8v-2h2v4H2Z" />
            </svg>
            Download for macOS
          </a>
          <a className="btn btn-ghost btn-big" href="#install">
            Install with Homebrew
          </a>
        </div>
        <div className="brew" role="group" aria-label="Homebrew install command">
          <code>{BREW_CMD}</code>
          <CopyButton text={BREW_CMD} />
        </div>
        <div className="meta-row">
          <span>
            <b>One</b> shared Linux VM
          </span>
          <span>
            <b>Full</b> clean-Mac bundle
          </span>
          <span>
            <b>0</b> Electron · <b>0</b> telemetry
          </span>
          <span>
            <b>GPL-3.0</b> · yours forever
          </span>
        </div>
      </div>
    </section>
  )
}

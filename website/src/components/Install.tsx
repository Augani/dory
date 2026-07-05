import { useState } from 'react'
import { Reveal } from './Reveal'
import { GithubIcon } from './GithubIcon'

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

export function Install() {
  return (
    <section id="install">
      <div className="wrap">
        <Reveal as="span" className="kicker">
          Get started
        </Reveal>
        <Reveal as="h2">Up and running in a minute.</Reveal>
        <Reveal className="install-card">
          <p style={{ color: 'var(--text-2)', fontSize: 15 }}>
            Install with Homebrew, or grab the notarized app from GitHub Releases. First launch walks
            you through the rest, engine included.
          </p>
          <div className="brew" role="group" aria-label="Homebrew install command">
            <code>{BREW_CMD}</code>
            <CopyButton text={BREW_CMD} />
          </div>
          <div className="cta-row" style={{ marginTop: 24 }}>
            <a
              className="btn btn-primary"
              href="https://github.com/Augani/dory/releases/latest"
              target="_blank"
              rel="noopener"
            >
              Download the latest release →
            </a>
          </div>
          <p className="req">
            <b>Apple silicon, macOS 15+</b> for Dory's own low-memory engine — nothing else to install.
            On Intel, Dory runs as a native front-end for a Docker-compatible engine you install
            (Colima, Docker Desktop, Rancher Desktop, Podman, OrbStack); a native Intel engine is
            planned for a later update.
          </p>
        </Reveal>
        <Reveal className="oss">
          <a className="btn btn-ghost" href="https://github.com/Augani/dory" target="_blank" rel="noopener">
            <GithubIcon /> Star Dory on GitHub
          </a>
          <a
            className="btn btn-ghost"
            href="https://github.com/Augani/dory/blob/main/CONTRIBUTING.md"
            target="_blank"
            rel="noopener"
          >
            Contribute
          </a>
        </Reveal>
      </div>
    </section>
  )
}

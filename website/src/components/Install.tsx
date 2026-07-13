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
            Install with Homebrew, or grab the notarized Apple Silicon app from GitHub Releases.
            Full downloads include the engine and host CLIs; the lite app fronts an engine you
            already run. Intel support is planned for a later release phase.
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
            <b>Apple Silicon with macOS 14+ (Sonoma)</b>. Full
            downloads bundle the Dory engine, doryd, Docker, Compose, kubectl, kernels, and rootfs
            assets so Docker works on a clean Mac. Hardware or asset gates degrade to a
            Docker-compatible local engine instead of blocking the app.
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

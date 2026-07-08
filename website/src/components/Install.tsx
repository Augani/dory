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
            Install with Homebrew, or grab the notarized Apple-silicon, Intel, or universal app from
            GitHub Releases. Full downloads include the engine and host CLIs; the lite app fronts an
            engine you already run.
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
            <b>macOS 14+ (Sonoma) on Apple silicon or Intel</b>, the same floor as OrbStack. The
            built-in low-memory engine needs macOS 15+ on Apple silicon; on macOS 14 Dory drives a
            Docker-compatible engine. Intel builds prefer the raw{" "}
            <code className="inline-code">dory-hv</code> beta when PVH assets are bundled, fall back
            to the Virtualization.framework helper when VZ assets are bundled, and can always proxy
            a Docker-compatible local engine.
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

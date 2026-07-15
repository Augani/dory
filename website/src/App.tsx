import { useState } from 'react'
import {
  ArrowRightIcon,
  CheckIcon,
  ClipboardDocumentIcon,
  CodeBracketIcon,
  CommandLineIcon,
  CpuChipIcon,
  CubeTransparentIcon,
  GlobeAltIcon,
  HeartIcon,
  ServerStackIcon,
  ShieldCheckIcon,
  SparklesIcon,
} from '@heroicons/react/24/outline'
import './App.css'

const installCommand = 'brew install --cask Augani/dory/dory'

const features = [
  {
    icon: CubeTransparentIcon,
    eyebrow: 'Docker, complete',
    title: 'Your workflow, unchanged.',
    copy: 'Run, build, pull, compose, inspect, and exec with the Docker commands you already know. Dory bundles the CLI, Buildx, Compose, and kubectl.',
  },
  {
    icon: CpuChipIcon,
    eyebrow: 'One shared VM',
    title: 'Built to give memory back.',
    copy: 'Every container shares one purpose-built Linux VM. As workloads idle, Dory reports free pages back to macOS instead of holding your memory hostage.',
  },
  {
    icon: GlobeAltIcon,
    eyebrow: 'Invisible networking',
    title: 'Local domains. Real HTTPS.',
    copy: 'Published ports land on localhost, while every container can get a memorable *.dory.local address with trusted local HTTPS.',
  },
  {
    icon: ServerStackIcon,
    eyebrow: 'More than containers',
    title: 'Kubernetes and Linux machines.',
    copy: 'Start k3s with one click or create persistent Dory Linux machines with snapshots, resource controls, and ready-to-code recipes.',
  },
  {
    icon: ShieldCheckIcon,
    eyebrow: 'Private by design',
    title: 'No account. No telemetry.',
    copy: 'Dory is a native Swift app without a bundled browser, phone-home loop, sign-in, or commercial-use tier. Your work stays on your Mac.',
  },
  {
    icon: SparklesIcon,
    eyebrow: 'Apple GPU bridge',
    title: 'Linux meets Metal.',
    copy: 'Reach Ollama, LM Studio, MLX, or llama.cpp on macOS from your containers through host.dory.internal—without moving the model.',
  },
]

const details = [
  ['Native SwiftUI', 'No Electron. No Chromium. Just a fast, quiet Mac app.'],
  ['One data drive', 'Containers, images, volumes, machines, and snapshots stay together.'],
  ['Migration built in', 'Bring your work from Docker Desktop or OrbStack with a preflight first.'],
  ['Self-diagnosing', 'Doctor, repair, routes, disk, and support tools are included.'],
]

function App() {
  const [copied, setCopied] = useState(false)

  const copyInstall = async () => {
    await navigator.clipboard.writeText(installCommand)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1800)
  }

  return (
    <div className="site-shell">
      <nav className="nav" aria-label="Main navigation">
        <a className="wordmark" href="#top" aria-label="Dory home">
          <img src="./logo.svg" alt="" />
          <span>Dory</span>
        </a>
        <div className="nav-links">
          <a href="#features">Features</a>
          <a href="https://github.com/Augani/dory">GitHub</a>
        </div>
        <a className="nav-cta" href="https://github.com/Augani/dory/releases/latest">
          Download <ArrowRightIcon />
        </a>
      </nav>

      <main id="top">
        <section className="hero">
          <div className="hero-glow" aria-hidden="true" />
          <div className="hero-copy">
            <div className="badge"><span /> Free and open source for macOS</div>
            <h1>Containers feel<br /><em>at home</em> on Mac.</h1>
            <p className="hero-lede">
              Docker, Kubernetes, and persistent Dory Linux machines in one beautifully native app.
              One shared VM. Zero accounts. Your existing tools just work.
            </p>
            <div className="hero-actions">
              <a className="primary-button" href="https://github.com/Augani/dory/releases/latest">
                Download for Apple silicon <ArrowRightIcon />
              </a>
              <a className="secondary-button" href="https://github.com/Augani/dory">
                <CodeBracketIcon /> View on GitHub
              </a>
            </div>
            <p className="requirement">Requires macOS 14 or later · Apple silicon</p>
          </div>

          <div className="app-stage">
            <div className="stage-orbit orbit-one" />
            <div className="stage-orbit orbit-two" />
            <div className="app-window">
              <div className="window-bar">
                <div className="traffic-lights"><i /><i /><i /></div>
                <span>Dory</span>
                <div />
              </div>
              <img src="./screenshot.png" alt="Dory app showing containers and their live status" />
            </div>
            <div className="floating-chip chip-left"><span className="pulse" /> Engine running</div>
            <div className="floating-chip chip-right"><CpuChipIcon /> Memory reclaimed</div>
          </div>

          <div className="trust-row" aria-label="Product highlights">
            <span><CheckIcon /> Docker compatible</span>
            <span><CheckIcon /> Native SwiftUI</span>
            <span><CheckIcon /> GPL-3.0</span>
            <span><CheckIcon /> No telemetry</span>
          </div>
        </section>

        <section className="manifesto">
          <p className="section-label">Why Dory</p>
          <h2>Your containers shouldn’t need<br />a <span>second computer</span> to run.</h2>
          <p>
            Dory was built around a simple idea: container tooling on a Mac should feel like it belongs there.
            No heavy web shell. No subscription. No mysterious background activity.
          </p>
        </section>

        <section className="feature-grid" id="features">
          {features.map(({ icon: Icon, eyebrow, title, copy }, index) => (
            <article className={`feature-card feature-${index + 1}`} key={title}>
              <div className="feature-icon"><Icon /></div>
              <p>{eyebrow}</p>
              <h3>{title}</h3>
              <span>{copy}</span>
            </article>
          ))}
        </section>

        <section className="product-story">
          <div className="story-copy">
            <p className="section-label">One calm control room</p>
            <h2>See everything.<br />Manage anything.</h2>
            <p>
              Containers, images, volumes, networks, Compose projects, Kubernetes, and Linux machines—without bouncing between tools.
            </p>
            <ul>
              {['Live logs, stats, and embedded terminals', 'Volume browser and image management', 'Pod exec, scaling, restarts, and rollouts'].map((item) => (
                <li key={item}><CheckIcon /> {item}</li>
              ))}
            </ul>
          </div>
          <div className="demo-frame">
            <img src="./demo.gif" alt="Dory interface walkthrough" loading="lazy" />
          </div>
        </section>

        <section className="details-section">
          <div className="details-intro">
            <p className="section-label">Made for the long run</p>
            <h2>Quiet when idle.<br />Ready when you are.</h2>
          </div>
          <div className="detail-list">
            {details.map(([title, copy], index) => (
              <div className="detail-row" key={title}>
                <span>0{index + 1}</span>
                <h3>{title}</h3>
                <p>{copy}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="install-section" id="install">
          <HeartIcon className="install-heart" />
          <p className="section-label">Yours, completely</p>
          <h2>Free for everyone.<br />Forever.</h2>
          <p>No seat limits, no sign-in, and no paid tier. Install Dory and get back to building.</p>
          <button className="command" type="button" onClick={copyInstall} aria-label="Copy Homebrew install command">
            <CommandLineIcon />
            <code>{installCommand}</code>
            <span>{copied ? <CheckIcon /> : <ClipboardDocumentIcon />}{copied ? 'Copied' : 'Copy'}</span>
          </button>
          <div className="install-actions">
            <a className="primary-button light" href="https://github.com/Augani/dory/releases/latest">Get Dory <ArrowRightIcon /></a>
            <a href="https://github.com/Augani/dory/stargazers">Star on GitHub</a>
          </div>
        </section>
      </main>

      <footer>
        <a className="wordmark" href="#top"><img src="./logo.svg" alt="" /><span>Dory</span></a>
        <p>Docker &amp; Linux containers, native to your Mac.</p>
        <div>
          <a href="https://github.com/Augani/dory">GitHub</a>
          <a href="https://github.com/Augani/dory/releases/latest">Releases</a>
          <a href="https://github.com/Augani/dory/blob/main/LICENSE">License</a>
        </div>
      </footer>
    </div>
  )
}

export default App

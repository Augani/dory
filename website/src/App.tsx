import { useEffect, useMemo, useRef, useState } from 'react'
import { animate, createTimeline, stagger } from 'animejs'
import {
  ArrowDownTrayIcon,
  ArrowRightIcon,
  ArrowTopRightOnSquareIcon,
  CheckIcon,
  ClipboardDocumentCheckIcon,
  ClipboardDocumentIcon,
  CommandLineIcon,
  CpuChipIcon,
  CubeIcon,
  GlobeAltIcon,
  MicrophoneIcon,
  SpeakerWaveIcon,
  VideoCameraIcon,
  XMarkIcon,
  Bars3Icon,
} from '@heroicons/react/24/outline'
import './App.css'

const installCommand = 'brew install --cask Augani/dory/dory'
const releaseUrl = 'https://github.com/Augani/dory/releases/latest'
const repositoryUrl = 'https://github.com/Augani/dory'
const componentPublicKey = 'AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4='

type ComponentId = 'docker-core' | 'kubernetes' | 'linux-machines' | 'linux-desktop' | 'desktop-debian' | 'desktop-ubuntu' | 'desktop-kali'

type ComponentRelease = {
  id: ComponentId
  version: string
  displayName: string
  summary: string
  dependencies: ComponentId[]
  downloadBytes: number
  installedBytes: number
}

type ComponentCatalog = {
  kind: 'dev.dory.component-catalog'
  schemaVersion: 1
  releaseVersion: string
  architecture: 'arm64'
  components: ComponentRelease[]
}

const componentOrder: ComponentId[] = ['docker-core', 'kubernetes', 'linux-machines', 'linux-desktop', 'desktop-debian', 'desktop-ubuntu', 'desktop-kali']
const selectableComponents: ComponentId[] = ['docker-core', 'kubernetes', 'linux-machines', 'desktop-ubuntu', 'desktop-debian', 'desktop-kali']
const componentLabels: Record<ComponentId, string> = {
  'docker-core': 'Docker Core',
  kubernetes: 'Kubernetes',
  'linux-machines': 'Linux Machines',
  'linux-desktop': 'Linux Desktop Runtime',
  'desktop-debian': 'Debian 13',
  'desktop-ubuntu': 'Ubuntu 24.04 LTS',
  'desktop-kali': 'Kali Linux',
}

function formatBytes(bytes: number) {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  const units = ['B', 'KiB', 'MiB', 'GiB']
  const unit = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
  const value = bytes / 1024 ** unit
  return `${unit < 2 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`
}

function validCatalog(value: unknown): value is ComponentCatalog {
  if (!value || typeof value !== 'object') return false
  const catalog = value as Partial<ComponentCatalog>
  const ids = catalog.components?.map((component) => component?.id) ?? []
  return catalog.kind === 'dev.dory.component-catalog'
    && catalog.schemaVersion === 1
    && catalog.architecture === 'arm64'
    && typeof catalog.releaseVersion === 'string'
    && componentOrder.every((id) => ids.includes(id))
}

function decodeBase64(value: string) {
  const decoded = atob(value.trim())
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0))
}

async function verifyCatalog(data: ArrayBuffer, signature: string) {
  const key = await crypto.subtle.importKey('raw', decodeBase64(componentPublicKey), { name: 'Ed25519' }, false, ['verify'])
  return crypto.subtle.verify({ name: 'Ed25519' }, key, decodeBase64(signature), data)
}

function DownloadBuilder() {
  const [catalog, setCatalog] = useState<ComponentCatalog | null>(null)
  const [catalogUnavailable, setCatalogUnavailable] = useState(false)
  const [selected, setSelected] = useState<Set<ComponentId>>(new Set(['docker-core']))

  useEffect(() => {
    const controller = new AbortController()
    Promise.all([
      fetch('./components/arm64/catalog.json', { cache: 'no-store', signal: controller.signal }),
      fetch('./components/arm64/catalog.json.sig', { cache: 'no-store', signal: controller.signal }),
    ])
      .then(async ([catalogResponse, signatureResponse]) => {
        if (!catalogResponse.ok || !signatureResponse.ok) throw new Error('catalog unavailable')
        const [data, signature] = await Promise.all([catalogResponse.arrayBuffer(), signatureResponse.text()])
        if (!await verifyCatalog(data, signature)) throw new Error('catalog signature invalid')
        return JSON.parse(new TextDecoder().decode(data)) as unknown
      })
      .then((value) => {
        if (!validCatalog(value)) throw new Error('catalog invalid')
        setCatalog(value)
      })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === 'AbortError') return
        setCatalogUnavailable(true)
      })
    return () => controller.abort()
  }, [])

  const releases = useMemo(() => new Map(catalog?.components.map((component) => [component.id, component]) ?? []), [catalog])

  if (!catalog) {
    return (
      <div className="catalog-state" role="status">
        <span className="catalog-pulse" />
        <div>
          <strong>{catalogUnavailable ? 'Signed component catalog unavailable' : 'Verifying the signed release'}</strong>
          <p>Dory only shows download sizes after the release catalog has been verified.</p>
          {catalogUnavailable && <a href={releaseUrl}>Use the GitHub release <ArrowRightIcon /></a>}
        </div>
      </div>
    )
  }

  const selectedReleases = componentOrder.flatMap((id) => selected.has(id) && releases.has(id) ? [releases.get(id)!] : [])
  const downloadBytes = selectedReleases.reduce((sum, component) => sum + component.downloadBytes, 0)
  const installedBytes = selectedReleases.reduce((sum, component) => sum + component.installedBytes, 0)
  const optionalIDs = componentOrder.filter((id) => id !== 'docker-core' && selected.has(id))
  const coreDmgUrl = `https://github.com/Augani/dory/releases/download/v${catalog.releaseVersion}/Dory-${catalog.releaseVersion}-arm64.dmg`
  const selectionUrl = `dory://components/install?ids=${encodeURIComponent(optionalIDs.join(','))}`

  const toggle = (id: ComponentId) => {
    if (id === 'docker-core') return
    setSelected((current) => {
      const next = new Set(current)
      if (next.has(id)) {
        next.delete(id)
        if (id.startsWith('desktop-') && !['desktop-debian', 'desktop-ubuntu', 'desktop-kali'].some((desktop) => next.has(desktop as ComponentId))) next.delete('linux-desktop')
      } else {
        next.add(id)
        releases.get(id)?.dependencies.forEach((dependency) => next.add(dependency))
      }
      next.add('docker-core')
      return next
    })
  }

  return (
    <div className="download-builder">
      <div className="download-builder-head">
        <div>
          <span>Release {catalog.releaseVersion} · Apple Silicon</span>
          <h3>Start small. Add exactly what you need.</h3>
        </div>
        <div className="download-totals" aria-live="polite">
          <div><strong>{formatBytes(downloadBytes)}</strong><span>Download</span></div>
          <div><strong>{formatBytes(installedBytes)}</strong><span>Installed</span></div>
        </div>
      </div>

      <div className="component-list">
        {selectableComponents.map((id) => {
          const component = releases.get(id)!
          const active = selected.has(id)
          return (
            <button key={id} type="button" className={`component-row${active ? ' is-selected' : ''}`} aria-pressed={active} onClick={() => toggle(id)}>
              <span className="component-toggle">{active ? <CheckIcon /> : null}</span>
              <span><strong>{componentLabels[id]}</strong><small>{component.summary}</small></span>
              <em>{id === 'docker-core' ? 'Required' : formatBytes(component.downloadBytes)}</em>
            </button>
          )
        })}
      </div>

      <div className="download-builder-foot">
        <div>
          <strong>{selectedReleases.map((component) => componentLabels[component.id]).join(' + ')}</strong>
          <span>Optional components install after Dory opens.</span>
        </div>
        <div className="download-actions">
          <a className="button button-inverse" href={coreDmgUrl}><ArrowDownTrayIcon /> Download Dory</a>
          {optionalIDs.length > 0 && <a className="button button-outline-dark" href={selectionUrl}>Open selection <ArrowRightIcon /></a>}
        </div>
      </div>
    </div>
  )
}

function ProductFrame() {
  return (
    <div className="product-frame" aria-label="Dory running an Ubuntu Linux desktop">
      <div className="frame-bar">
        <div className="frame-mark"><img src="./logo.svg" alt="" /><span>Dory</span></div>
        <div className="frame-tabs"><span className="is-active">Ubuntu</span><span>Containers</span><span>Kubernetes</span></div>
        <div className="frame-status"><i /> Running</div>
      </div>
      <div className="frame-body">
        <aside>
          <span>Workspace</span>
          <b>Machines</b>
          <span>Containers</span>
          <span>Images</span>
          <span>Volumes</span>
          <span>Networks</span>
          <span>Agents</span>
        </aside>
        <div className="linux-canvas">
          <div className="linux-topbar"><span>Activities</span><span>28 Aug&nbsp;&nbsp; 10:42</span><span>⌁ &nbsp;◉</span></div>
          <div className="linux-wallpaper">
            <div className="terminal-window">
              <div><span /><span /><span /></div>
              <code><i>dory@workspace</i>:~$ uname -m<br /><b>arm64</b><br /><i>dory@workspace</i>:~$ docker ps<br /><b>3 services running</b><br /><i>dory@workspace</i>:~$ <span className="cursor" /></code>
            </div>
            <div className="device-dock">
              <span><VideoCameraIcon /> Camera</span>
              <span><MicrophoneIcon /> Microphone</span>
              <span><SpeakerWaveIcon /> Speakers</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

const sandboxProfiles = {
  'Auto-detect': ['package.json', 'Cargo.toml', 'Node 22 + Rust', 'npm test'],
  Node: ['package.json', 'pnpm-lock.yaml', 'Node 22', 'pnpm test'],
  Python: ['pyproject.toml', 'uv.lock', 'Python 3.13', 'pytest -q'],
  Go: ['go.mod', 'go.sum', 'Go 1.25', 'go test ./...'],
} as const

type SandboxProfile = keyof typeof sandboxProfiles

function AgentLab() {
  const [profile, setProfile] = useState<SandboxProfile>('Auto-detect')
  const [run, setRun] = useState(0)
  const labRef = useRef<HTMLDivElement>(null)
  const details = sandboxProfiles[profile]

  useEffect(() => {
    const root = labRef.current
    if (!root || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const steps = root.querySelectorAll('.agent-step')
    const nodes = root.querySelectorAll('.provision-node')
    const timeline = createTimeline({ defaults: { duration: 320, ease: 'outQuad' } })
    timeline
      .set(steps, { opacity: 0, y: 8 })
      .set(nodes, { scale: .92, opacity: .28 })
      .add(steps, { opacity: 1, y: 0, delay: stagger(260) }, 120)
      .add(nodes, { scale: 1, opacity: 1, delay: stagger(190), duration: 380 }, 420)
    return () => { timeline.revert() }
  }, [profile, run])

  return (
    <div className="agent-lab" ref={labRef}>
      <div className="lab-toolbar">
        <div><span className="live-dot" /> Live sandbox creation</div>
        <button type="button" onClick={() => setRun((value) => value + 1)}>Replay build <ArrowRightIcon /></button>
      </div>
      <div className="agent-lab-body">
        <div className="profile-picker" aria-label="Sandbox language profile">
          <span>Language runtime</span>
          {(Object.keys(sandboxProfiles) as SandboxProfile[]).map((name) => (
            <button className={profile === name ? 'is-active' : ''} key={name} type="button" onClick={() => setProfile(name)}>{name}</button>
          ))}
        </div>
        <div className="provision-map" aria-hidden="true">
          <span className="provision-node">Project</span><i />
          <span className="provision-node">Policy</span><i />
          <span className="provision-node">ARM64 VM</span><i />
          <span className="provision-node">Baseline</span>
        </div>
        <div className="agent-console">
          <div className="terminal-title"><span>atlas · creation log</span><span>isolated · non-root</span></div>
          <code>
            <span className="agent-step"><i>$</i> dory sandbox create atlas --workspace .</span>
            <span className="agent-step"><b>inspect</b> Found {details[0]} + {details[1]}</span>
            <span className="agent-step"><b>runtime</b> Preparing {details[2]}</span>
            <span className="agent-step"><b>policy</b> /workspace mounted · network outbound</span>
            <span className="agent-step"><b>baseline</b> Sparse disk prepared · reset point captured</span>
            <span className="agent-step is-success"><b>ready</b> atlas is ready in 1.8s</span>
            <span className="agent-step"><i>$</i> dory sandbox exec atlas -- {details[3]}</span>
          </code>
        </div>
      </div>
    </div>
  )
}

function ResourceLab() {
  const [mode, setMode] = useState<'active' | 'reclaimed' | 'sleeping'>('active')
  const meterRef = useRef<HTMLDivElement>(null)
  const modes = {
    active: { engine: 'Running', host: 72, guest: 54, resident: '2.4 GB', detail: 'Working set protected' },
    reclaimed: { engine: 'Running', host: 39, guest: 31, resident: '1.2 GB', detail: 'Unused pages returned to macOS' },
    sleeping: { engine: 'Sleeping', host: 8, guest: 0, resident: '86 MB', detail: 'Engine stopped · data preserved' },
  }
  const current = modes[mode]

  useEffect(() => {
    const fills = meterRef.current?.querySelectorAll('.meter-fill')
    if (!fills || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const animation = animate(fills, { scaleX: [0, 1], duration: 680, delay: stagger(90), ease: 'outExpo' })
    return () => { animation.revert() }
  }, [mode])

  return (
    <div className="resource-lab" ref={meterRef}>
      <div className="resource-lab-head">
        <div><span className={`engine-indicator ${mode}`} /> <strong>{current.engine}</strong><small>{current.detail}</small></div>
        <div className="mode-switcher" aria-label="Engine memory state">
          <button type="button" className={mode === 'active' ? 'is-active' : ''} onClick={() => setMode('active')}>In use</button>
          <button type="button" className={mode === 'reclaimed' ? 'is-active' : ''} onClick={() => setMode('reclaimed')}>Reclaimed</button>
          <button type="button" className={mode === 'sleeping' ? 'is-active' : ''} onClick={() => setMode('sleeping')}>Auto-idle</button>
        </div>
      </div>
      <div className="resource-meters">
        <article><span>Engine memory ceiling</span><strong>{current.host}%</strong><div><i className="meter-fill" style={{ width: `${current.host}%` }} /></div><small>Pressure-aware host allocation</small></article>
        <article><span>Guest working set</span><strong>{current.guest}%</strong><div><i className="meter-fill" style={{ width: `${current.guest}%` }} /></div><small>Cache and reclaimable pages separated</small></article>
        <article><span>Total resident memory</span><strong>{current.resident}</strong><div><i className="meter-fill" style={{ width: mode === 'active' ? '64%' : mode === 'reclaimed' ? '32%' : '7%' }} /></div><small>App, daemon, engine, network, helpers</small></article>
      </div>
      <div className="resource-foot"><span>Published ports</span><b>{mode === 'sleeping' ? 'none' : '3000, 5432'}</b><span>Kubernetes</span><b>{mode === 'active' ? 'keeps awake' : 'stopped'}</b><span>Next action</span><b>{mode === 'sleeping' ? 'wake on demand' : 'observe'}</b></div>
    </div>
  )
}

function App() {
  const [menuOpen, setMenuOpen] = useState(false)
  const [copied, setCopied] = useState(false)

  const copyInstall = async () => {
    await navigator.clipboard.writeText(installCommand)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1800)
  }

  return (
    <div className="site-shell">
      <header className="site-header">
        <a className="wordmark" href="#top" aria-label="Dory home"><img src="./logo.svg" alt="" /><span>Dory</span></a>
        <nav className={menuOpen ? 'is-open' : ''} aria-label="Main navigation">
          <a href="./experience/" onClick={() => setMenuOpen(false)}>Experience</a>
          <a href="#platform" onClick={() => setMenuOpen(false)}>Platform</a>
          <a href="#engineering" onClick={() => setMenuOpen(false)}>Engineering</a>
          <a href="#linux" onClick={() => setMenuOpen(false)}>Linux</a>
          <a href="#roadmap" onClick={() => setMenuOpen(false)}>Roadmap</a>
          <a href="./docs/compatibility.md">Compatibility</a>
          <a href={repositoryUrl}>GitHub <ArrowTopRightOnSquareIcon /></a>
        </nav>
        <a className="header-cta" href="#download">Download</a>
        <button className="menu-button" type="button" aria-label={menuOpen ? 'Close menu' : 'Open menu'} aria-expanded={menuOpen} onClick={() => setMenuOpen((open) => !open)}>
          {menuOpen ? <XMarkIcon /> : <Bars3Icon />}
        </button>
      </header>

      <main>
        <section className="hero" id="top">
          <div className="hero-copy">
            <p className="section-label">Local development, without compromise</p>
            <h1>The development computer, rethought.</h1>
            <p className="hero-lede">Dory is a complete local development system: a native container engine, Kubernetes, full Linux computers, secure agent sandboxes, networking, storage, recovery, and automation—engineered as one whole.</p>
            <div className="hero-actions">
              <a className="button button-primary" href="#download">Download for Mac <ArrowRightIcon /></a>
              <a className="button button-experience" href="./experience/">Enter Dory <ArrowRightIcon /></a>
              <button className="command-button" type="button" onClick={copyInstall} aria-label="Copy Homebrew install command">
                <CommandLineIcon /><code>{installCommand}</code>{copied ? <ClipboardDocumentCheckIcon /> : <ClipboardDocumentIcon />}
              </button>
            </div>
            <p className="hero-note">Free. Open source. No account required.</p>
          </div>
          <ProductFrame />
        </section>

        <section className="capability-band" aria-label="Dory capabilities">
          {['Docker engine', 'Compose + Buildx', 'Kubernetes', 'Linux computers', 'Agent sandboxes', 'Migration + recovery'].map((capability) => <span key={capability}>{capability}</span>)}
        </section>

        <section className="platform section" id="platform">
          <div className="chapter-heading">
            <p className="section-label">One local platform</p>
            <h2>Everything your work needs. <span>Nothing between you and the machine.</span></h2>
          </div>
          <div className="platform-grid">
            <div className="platform-intro">
              <p>Dory replaces the scattered stack of container runtimes, virtual machines, local clusters, and agent environments with one coherent system.</p>
              <a className="text-link" href="./docs/architecture.md">Read the architecture <ArrowRightIcon /></a>
            </div>
            <div className="feature-rows">
              <article><span>01</span><div><h3>Containers that speak Docker</h3><p>A native engine for Docker CLI, Compose, Buildx, Testcontainers, and the tools you already use.</p></div><CubeIcon /></article>
              <article><span>02</span><div><h3>Kubernetes without ceremony</h3><p>Bring up a local k3s cluster beside your containers, with selectable versions and clear lifecycle controls.</p></div><GlobeAltIcon /></article>
              <article><span>03</span><div><h3>Machines with real boundaries</h3><p>Persistent Linux servers and disposable agent sandboxes, each with its own disk, network, and resources.</p></div><CpuChipIcon /></article>
            </div>
          </div>
        </section>

        <section className="engineering section" id="engineering">
          <div className="chapter-heading">
            <p className="section-label">The invisible engineering</p>
            <h2>Fast when you need it. <span>Quiet when you don’t.</span></h2>
          </div>
          <div className="engineering-intro">
            <p>A local runtime should not become the biggest workload on your Mac. Dory measures the host and every guest, protects real working sets, reclaims idle cache, and can put the engine fully to sleep when nothing depends on it.</p>
            <div className="engineering-notes">
              <span>Host pressure sampled</span><span>Guest PSI observed</span><span>Working set protected</span><span>Explicit wake blockers</span>
            </div>
          </div>
          <ResourceLab />
          <div className="engineering-ledger">
            <article><span>01</span><h3>Memory that gives back</h3><p>Dory separates guest-used, cached, and reclaimable memory. Its balloon policy reacts to host pressure in bounded steps while keeping headroom above each guest’s measured working set.</p></article>
            <article><span>02</span><h3>Idle is a real state</h3><p>Auto-Idle waits 5, 15, 30, or 60 minutes, but published ports, Kubernetes, or pinned projects can deliberately keep the engine awake. Battery Saver caps that delay at five minutes.</p></article>
            <article><span>03</span><h3>Wake with context</h3><p>The daemon records why the engine slept, what blocked it, and how it woke. A request brings the system back through ordered readiness gates—not a blind process restart.</p></article>
          </div>
        </section>

        <section className="linux section-dark" id="linux">
          <div className="linux-heading">
            <p className="section-label section-label-light">Desktop Linux</p>
            <h2>Not a terminal pretending to be a computer.</h2>
            <p>Install a compatible ARM64 Linux ISO or choose a managed Ubuntu, Debian, or Kali desktop. Then use it like a machine—with display, keyboard, pointer, network, camera, microphone, and speakers.</p>
          </div>
          <div className="linux-stage">
            <ProductFrame />
          </div>
          <div className="linux-facts">
            <article><strong>Bring your ISO</strong><p>Architecture preflight, secure private import, EFI boot, persistent NVRAM, install, eject, and reboot.</p></article>
            <article><strong>Use your Mac hardware</strong><p>Responsive display and input, shared networking, audio in and out, plus camera controls.</p></article>
            <article><strong>Keep the machine</strong><p>Thin-provisioned disks, snapshots, backups, cloning, import, export, and recovery are built in.</p></article>
          </div>
        </section>

        <section className="agents section">
          <div className="agents-copy agents-heading">
            <p className="section-label">Built for what comes next</p>
            <h2>Give every agent a real machine.</h2>
            <div><p>Dory detects Node, Python, Go, Rust, Java, and Ruby projects, prepares the right toolchains, captures a clean reset baseline, and keeps caches warm between commands—all inside a non-root ARM64 VM with explicit mounts, network policy, timeouts, and a kill switch.</p><a className="text-link" href="./docs/agents.md">Explore the full sandbox contract <ArrowRightIcon /></a></div>
          </div>
          <AgentLab />
          <div className="agent-guardrails">
            <span>No host files by default</span><span>Read-only mounts by default</span><span>None, allowlisted, or full network</span><span>Ephemeral secrets and SSH grants</span><span>Rollback and TTL cleanup</span>
          </div>
        </section>

        <section className="systems section-dark">
          <div className="systems-heading">
            <p className="section-label section-label-light">A system of contracts</p>
            <h2>Every transition has evidence.</h2>
            <p>Dory does not treat “the process started” as “your environment is ready.” Boot, repair, upgrade, migration, and recovery advance only when the layer that owns the next fact can prove it.</p>
          </div>
          <div className="readiness-rail" aria-label="Dory readiness stages">
            {['App', 'doryd', 'VM', 'Guest agent', 'Data drive', 'Network', 'Docker', 'Host context', 'Kubernetes'].map((stage, index) => (
              <div key={stage}><span>{String(index + 1).padStart(2, '0')}</span><i /><strong>{stage}</strong><small>{index === 7 ? 'when enabled' : 'verified'}</small></div>
            ))}
          </div>
          <div className="systems-grid">
            <article><span>Transactional migration</span><h3>Bring the work, not just the images.</h3><p>Select containers, volumes, networks, and dependencies. Dory inventories the source, rejects drift, stages the transfer, validates the destination, and rolls the whole operation back if the evidence does not close.</p></article>
            <article><span>Verified recovery</span><h3>A backup has to prove it can return.</h3><p>Scheduled machine backups snapshot, export, re-import, and periodically boot a disposable verifier. Manual snapshots remain untouched, and archives publish atomically only after verification.</p></article>
            <article><span>Targeted repair</span><h3>Repair the layer that failed.</h3><p>Socket, guest-agent, Docker, route, and data-drive repairs have separate owners and budgets. A healthy data plane is not restarted to make a status light green.</p></article>
          </div>
        </section>

        <section className="networking section">
          <div className="networking-grid">
            <div>
              <p className="section-label">Local, without feeling small</p>
              <h2>Names, HTTPS, LAN, VPN, and host services—resolved as one network.</h2>
              <p>Dory gives local workloads stable domains, trusted HTTPS, low ports, configurable DNS and proxies, split-DNS and scoped CA policy, plus explicit LAN and Tailscale access. Every system change has a preview, an owner, and a removal plan.</p>
            </div>
            <div className="route-demo">
              <div><span>Request</span><code>https://api.myproject.dory.local</code></div>
              <i />
              <div><span>Dory route</span><code>container: api · port 3000</code></div>
              <i />
              <div><span>Result</span><code>200 OK · trusted local TLS</code></div>
              <aside><span>VPN-aware</span><span>IPv6 where available</span><span>Source-preserving LAN mode</span></aside>
            </div>
          </div>
        </section>

        <section className="roadmap section" id="roadmap">
          <div className="chapter-heading">
            <p className="section-label">The platform ahead</p>
            <h2>Mac is the beginning. <span>The development computer is the destination.</span></h2>
          </div>
          <div className="roadmap-line">
            <article className="is-now"><span>Available now</span><h3>Linux on Apple Silicon</h3><p>Containers, clusters, servers, managed desktops, compatible ARM64 ISOs, and agent sandboxes.</p></article>
            <article><span>In development</span><h3>Windows desktops</h3><p>Native Windows 11 ARM guests with the same deliberate machine, device, and recovery model.</p></article>
            <article><span>Planned</span><h3>macOS desktops</h3><p>Isolated macOS workspaces designed to sit beside Linux and Windows in one Dory library.</p></article>
          </div>
        </section>

        <section className="download section" id="download">
          <div className="chapter-heading">
            <p className="section-label">Get Dory</p>
            <h2>Your whole local stack. <span>Choose only the parts you need.</span></h2>
          </div>
          <DownloadBuilder />
          <p className="download-note">Requires Apple Silicon and macOS 14 or later. <a href={releaseUrl}>View signed release assets</a>.</p>
        </section>
      </main>

      <footer>
        <div className="footer-lockup"><img src="./logo.svg" alt="" /><strong>Dory</strong><p>Build locally. Go anywhere.</p></div>
        <div className="footer-links">
          <a href="./docs/compatibility.md">Compatibility</a>
          <a href="./docs/operations.md">Operations</a>
          <a href="./docs/performance.md">Performance</a>
          <a href={repositoryUrl}>Source</a>
          <a href="https://github.com/sponsors/Augani">Sponsor</a>
        </div>
        <p>GPL-3.0 · © 2026 Dory contributors</p>
      </footer>
    </div>
  )
}

export default App

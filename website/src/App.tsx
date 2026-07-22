import { useEffect, useState, type ComponentType, type CSSProperties, type SVGProps } from 'react'
import {
  ArrowRightIcon,
  ArrowTopRightOnSquareIcon,
  ArrowsRightLeftIcon,
  Bars3Icon,
  BeakerIcon,
  BoltIcon,
  CheckCircleIcon,
  CircleStackIcon,
  ClipboardDocumentCheckIcon,
  ClipboardDocumentIcon,
  CloudArrowDownIcon,
  CodeBracketIcon,
  CommandLineIcon,
  Cog6ToothIcon,
  CpuChipIcon,
  CubeIcon,
  GlobeAltIcon,
  LockClosedIcon,
  ServerStackIcon,
  ShieldCheckIcon,
  SparklesIcon,
  Squares2X2Icon,
  StarIcon,
  WrenchScrewdriverIcon,
  XMarkIcon,
} from '@heroicons/react/24/outline'
import './App.css'

type Icon = ComponentType<SVGProps<SVGSVGElement>>

const installCommand = 'brew install --cask Augani/dory/dory'
const releaseUrl = 'https://github.com/Augani/dory/releases/latest'
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

const componentOrder: ComponentId[] = [
  'docker-core',
  'kubernetes',
  'linux-machines',
  'linux-desktop',
  'desktop-debian',
  'desktop-ubuntu',
  'desktop-kali',
]

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

function validComponentCatalog(value: unknown): value is ComponentCatalog {
  if (!value || typeof value !== 'object') return false
  const catalog = value as Partial<ComponentCatalog>
  if (catalog.kind !== 'dev.dory.component-catalog' || catalog.schemaVersion !== 1 || catalog.architecture !== 'arm64') return false
  if (typeof catalog.releaseVersion !== 'string' || !/^[0-9A-Za-z.+_-]{1,64}$/.test(catalog.releaseVersion) || !Array.isArray(catalog.components)) return false
  const ids = catalog.components.map((component) => component?.id)
  return ids.length === componentOrder.length
    && new Set(ids).size === componentOrder.length
    && componentOrder.every((id) => ids.includes(id))
    && catalog.components.every((component) =>
    component
      && componentOrder.includes(component.id)
      && Number.isSafeInteger(component.downloadBytes)
      && component.downloadBytes > 0
      && Number.isSafeInteger(component.installedBytes)
      && component.installedBytes > 0
      && Array.isArray(component.dependencies)
      && component.dependencies.every((dependency) => componentOrder.includes(dependency)),
  )
}

function decodeBase64(value: string) {
  const decoded = atob(value.trim())
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0))
}

async function verifyComponentCatalog(data: ArrayBuffer, signature: string) {
  const key = await crypto.subtle.importKey(
    'raw',
    decodeBase64(componentPublicKey),
    { name: 'Ed25519' },
    false,
    ['verify'],
  )
  return crypto.subtle.verify(
    { name: 'Ed25519' },
    key,
    decodeBase64(signature),
    data,
  )
}

function FocusedDownloadSelector() {
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
        if (!catalogResponse.ok || !signatureResponse.ok) throw new Error('component catalog is unavailable')
        const [data, signature] = await Promise.all([catalogResponse.arrayBuffer(), signatureResponse.text()])
        if (!await verifyComponentCatalog(data, signature)) throw new Error('component catalog signature is invalid')
        return JSON.parse(new TextDecoder().decode(data)) as unknown
      })
      .then((value) => {
        if (!validComponentCatalog(value)) throw new Error('component catalog is invalid')
        setCatalog(value)
      })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === 'AbortError') return
        setCatalogUnavailable(true)
      })
    return () => controller.abort()
  }, [])

  if (!catalog) {
    return (
      <div className="download-roadmap" role="status">
        <Squares2X2Icon aria-hidden="true" />
        <div>
          <strong>{catalogUnavailable ? 'The signed component catalog is temporarily unavailable.' : 'Verifying the signed component catalog…'}</strong>
          <p>Dory does not show a download until it can verify the exact Docker Core and optional component sizes. You can also use the GitHub release page while this check recovers.</p>
          {catalogUnavailable && <a className="text-link" href={releaseUrl}>View signed release assets <ArrowRightIcon /></a>}
        </div>
      </div>
    )
  }

  const releases = new Map(catalog.components.map((component) => [component.id, component]))
  const selectedReleases = componentOrder.flatMap((id) => selected.has(id) && releases.has(id) ? [releases.get(id)!] : [])
  const downloadBytes = selectedReleases.reduce((total, component) => total + component.downloadBytes, 0)
  const installedBytes = selectedReleases.reduce((total, component) => total + component.installedBytes, 0)
  const coreDmgUrl = `https://github.com/Augani/dory/releases/download/v${catalog.releaseVersion}/Dory-${catalog.releaseVersion}-arm64.dmg`
  const optionalSelectedIDs = componentOrder.filter((id) => id !== 'docker-core' && selected.has(id))
  const selectionUrl = `dory://components/install?ids=${encodeURIComponent(optionalSelectedIDs.join(','))}`

  const toggle = (id: ComponentId) => {
    if (id === 'docker-core' || id === 'linux-desktop') return
    setSelected((current) => {
      const next = new Set(current)
      if (next.has(id)) {
        next.delete(id)
        if (id.startsWith('desktop-') && !['desktop-debian', 'desktop-ubuntu', 'desktop-kali'].some((distro) => next.has(distro as ComponentId))) {
          next.delete('linux-desktop')
        }
      } else {
        next.add(id)
        for (const dependency of releases.get(id)?.dependencies ?? []) next.add(dependency)
      }
      next.add('docker-core')
      return next
    })
  }

  return (
    <div className="component-builder">
      <div className="component-builder-summary">
        <div>
          <span>Focused release {catalog.releaseVersion}</span>
          <h3>Your app stays small. Your workspace stays complete.</h3>
          <p>Docker Core is the only required download. Dory installs your optional signed components into the selected .dorydrive after the app opens, and can remove their payloads later without deleting workload data.</p>
        </div>
        <div className="component-totals" aria-live="polite">
          <div><strong>{formatBytes(downloadBytes)}</strong><span>core + selected downloads</span></div>
          <div><strong>{formatBytes(installedBytes)}</strong><span>installed payload</span></div>
        </div>
      </div>

      <div className="component-choice-grid">
        {componentOrder.filter((id) => id !== 'linux-desktop').map((id) => {
          const component = releases.get(id)!
          const required = id === 'docker-core'
          const active = selected.has(id)
          return (
            <button
              className={`component-choice${active ? ' is-selected' : ''}${required ? ' is-required' : ''}`}
              key={id}
              type="button"
              aria-pressed={active}
              onClick={() => toggle(id)}
            >
              <span className="component-check">{active ? '✓' : '+'}</span>
              <span className="component-choice-copy">
                <strong>{componentLabels[id]}</strong>
                <small>{required ? 'Required' : active ? 'Selected' : 'Optional'} · {formatBytes(component.downloadBytes)}</small>
                <p>{component.summary}</p>
              </span>
            </button>
          )
        })}
      </div>

      {selected.has('linux-desktop') && (
        <p className="component-runtime-note">
          <CheckCircleIcon /> Linux Desktop Runtime added automatically · {formatBytes(releases.get('linux-desktop')!.downloadBytes)}
        </p>
      )}
      {selected.has('kubernetes') && (
        <p className="component-runtime-note">
          <CheckCircleIcon /> The selected k3s container image downloads on first cluster creation and is not included in the component total.
        </p>
      )}

      <div className="component-builder-footer">
        <div className="component-builder-footer-copy">
          <strong>{selectedReleases.map((component) => componentLabels[component.id]).join(' + ')}</strong>
          <span>1. Download and open the Docker Core app.</span>
          {optionalSelectedIDs.length > 0
            ? <span>2. Open this selection in Dory, review the signed sizes, then confirm installation.</span>
            : <span>No optional component downloads are needed for this selection.</span>}
        </div>
        <div className="component-builder-actions">
          <a className="button button-primary" href={coreDmgUrl}><CloudArrowDownIcon /> Download Docker Core</a>
          {optionalSelectedIDs.length > 0 && (
            <a className="button button-component-open" href={selectionUrl}><Squares2X2Icon /> Open selection in Dory</a>
          )}
        </div>
      </div>
    </div>
  )
}

const surfaces: Array<{
  icon: Icon
  label: string
  title: string
  copy: string
  facts: string[]
  command: string
}> = [
  {
    icon: CubeIcon,
    label: 'Docker, complete',
    title: 'Keep the workflow. Replace the weight.',
    copy: 'Dory ships its own Docker 29 engine, CLI, Buildx, BuildKit, Compose v2, registries, file sharing, volumes, and networks.',
    facts: ['Standard Docker API', 'Private registries', 'Common amd64 images'],
    command: 'docker compose up -d',
  },
  {
    icon: Squares2X2Icon,
    label: 'Kubernetes, when needed',
    title: 'A local cluster without a second product.',
    copy: 'Add the signed kubectl component, then create k3s in one click and work with pods, deployments, services, configuration, secrets, and ingress from the app. The selected k3s image downloads on first enable.',
    facts: ['k3s v1.34 to v1.36', 'Signed kubectl component', 'Native resource browser'],
    command: 'dory k8s get pods -A',
  },
  {
    icon: ServerStackIcon,
    label: 'Real Linux machines',
    title: 'A full Linux desktop beside your containers.',
    copy: 'Create a managed Debian, Ubuntu, or Kali Xfce desktop for graphical and command-line apps, or choose lightweight headless Linux for services and agents.',
    facts: ['Three desktop distributions', 'Scoped Mac folders', 'Snapshot and clone'],
    command: 'dory machine shell dev',
  },
]

const desktopDistros = [
  ['Debian', '13', 'Stable, clean desktop for everyday Linux and development', '#a80030'],
  ['Ubuntu', '24.04 LTS', 'A familiar long-term-support base for development and daily work', '#e95420'],
  ['Kali Linux', 'Rolling', 'A focused security lab backed by Kali\'s official rolling repository', '#367bf0'],
]

const desktopCapabilities = [
  ['Real Linux guest', 'Native arm64, systemd, Xfce, Bash, apt, and normal graphical or command-line applications'],
  ['Retina display', 'A true 2x guest framebuffer follows the window and keeps the Xfce desktop sharp as it resizes'],
  ['Your identity', 'Choose the Linux username, CPU, memory, development recipe, and only the Mac folders to share'],
  ['Persistent and recoverable', 'A thin 64 GiB disk lives in the selected .dorydrive with snapshots, clone, import, and export'],
]

const cockpitFeatures = [
  ['Components', 'Install, update, verify, and remove focused payloads with exact sizes'],
  ['Containers', 'Live CPU and memory, logs, shell, ports, Compose groups'],
  ['Images', 'Pull, run, inspect, copy IDs, delete, and reclaim'],
  ['Volumes', 'Create, browse files, delete, and prune unused data'],
  ['Networks', 'Inspect custom networks, IPAM, attached containers, and cleanup'],
  ['Compose', 'Open YAML, start, stop, restart, and bring projects down'],
  ['Kubernetes', 'Apply YAML, exec, logs, scale, restart, and switch versions'],
  ['Linux Desktops', 'Create Debian, Ubuntu, or Kali, open its Retina display or terminal, snapshot, clone, import, and export'],
  ['Linux Servers', 'Run lightweight persistent Alpine VMs for terminals, services, tests, and agents'],
  ['Health', 'Passive checks, active probes, repair, history, and support bundles'],
]

const migrationObjects = [
  'Images and every visible tag',
  'Named volume contents',
  'Custom networks and IPAM',
  'Container configuration',
  'Writable container layers',
  'Ports and Compose labels',
  'Running, stopped, and paused state',
]

const agentTools = [
  'dory.agent_guide',
  'dory.doctor',
  'dory.compat',
  'dory.engine_status',
  'dory.machine_list',
  'dory.machine_exec',
  'dory.sandbox_run',
  'dory.wait',
  'dory.events',
]

const settings = [
  ['Components', 'Signed catalog, exact sizes, updates, verification, dependency-aware removal'],
  ['General', 'Startup, menu bar, terminal tools, preferred terminal app, browser logins, appearance'],
  ['Engine & Daemon', 'Backend, CPU, memory, amd64, preview guest GPU'],
  ['Resources', 'Data drive, backup, verify, restore, growth, process memory'],
  ['Machines', 'Host environment allow-list and file-sharing boundaries'],
  ['Auto-Idle', 'Availability mode, idle delay, blockers, wake notices'],
  ['Network', 'Automatic/custom domains, low ports, LAN/Tailscale, plus a reversible corporate proxy, registry, CA, split-DNS and VPN profile'],
  ['USB Devices', 'Scan host candidates; attach and detach stay disabled until USB/IP qualification'],
  ['Local Tools', 'Supported and preview daemon commands with copy actions'],
  ['Migrate & Compare', 'Source discovery, preflight, import, and comparison'],
  ['Managed', 'JSON defaults for fleets and MDM-friendly configuration'],
]

const faqs = [
  {
    question: 'Do I need Docker Desktop or a separate Docker CLI?',
    answer: 'No. Docker Core includes the engine, Docker CLI, Buildx, and Compose. Install the optional Kubernetes component when you also want kubectl and Dory\'s local k3s workflow.',
  },
  {
    question: 'Can I move from OrbStack, Docker Desktop, or Colima?',
    answer: 'Yes. Dory detects running Docker-compatible engines and shows a read-only preflight before import. It can copy images, named volumes, custom networks, container definitions, writable layers, ports, and workload state. The source is never deleted.',
  },
  {
    question: 'Can I change the memory seen by Docker and Minikube?',
    answer: 'Yes. Settings > Engine & Daemon exposes the engine CPU count and elastic memory ceiling. Applying a change restarts the engine and restores the containers that were running.',
  },
  {
    question: 'Do local file watchers work?',
    answer: 'Dory 0.3 qualifies host edit visibility, file locking, and watcher behavior for shared Mac paths. The mount and doctor commands can test the live setup when Vite, Tailwind, Webpack, or Rails does not rebuild.',
  },
  {
    question: 'Can Dory publish ports below 1024?',
    answer: 'Yes. Dory has a built-in macOS authorization plan for trusted HTTPS, ports 80 and 443, and published low TCP ports. Settings > Network also maps exact or wildcard custom domains to a published HTTP port, so nginx-style local domains do not need a second forwarding app.',
  },
  {
    question: 'Are Linux machines full desktop VMs?',
    answer: 'Yes on Apple Silicon. Choose managed Debian 13, Ubuntu 24.04 LTS, or Kali rolling with systemd, Xfce, Bash, a configurable user, a Retina-sharp resizable display, and a 64 GiB thin-provisioned disk. Lightweight Alpine headless machines remain available for terminal and service workloads.',
  },
  {
    question: 'Which Dory components should I install?',
    answer: 'Start with Docker Core. Add Kubernetes for k3s and kubectl, Linux Machines for headless VPS-style guests, or only the Debian, Ubuntu, and Kali desktop packs you use. Optional payloads live in the selected Dory data drive and can be removed independently.',
  },
  {
    question: 'How do I upgrade from an older Dory release?',
    answer: 'Use Settings > Updates for the normal signed in-place upgrade. Dory preflights the candidate and selected drive, records the exact last-known-good app, configuration and component generation, then runs next-launch workload smoke tests. Safe state rolls back automatically; an unsafe data-schema rollback stops with a recovery export instead of guessing.',
  },
  {
    question: 'Can I choose which terminal Dory opens?',
    answer: 'Yes. Settings > General can use the system default, Terminal, iTerm2, Ghostty, Warp, WezTerm, Alacritty, Kitty, or another application you select. The preference applies to container and Linux-machine terminal actions.',
  },
]

const releaseStates = [
  ['Supported', 'Docker, Compose, Kubernetes, Linux desktops and servers, migration, storage, networking, health, MCP, policy-enforced sandbox VMs, and USB discovery'],
  ['Preview', 'In-guest Venus/Vulkan, remote SSH workspace foundations, and bounded custom machine images'],
  ['Unavailable', 'USB passthrough, Intel host releases, desktop images beyond Debian/Ubuntu/Kali, and audio passthrough'],
]

type DemoView = 'containers' | 'kubernetes' | 'machines'

const demoViews: DemoView[] = ['containers', 'kubernetes', 'machines']

const demoNav: Array<{
  group: string
  items: Array<{ id: string; label: string; icon: Icon; count?: string }>
}> = [
  {
    group: 'DOCKER',
    items: [
      { id: 'containers', label: 'Containers', icon: CubeIcon, count: '4' },
      { id: 'images', label: 'Images', icon: CircleStackIcon },
      { id: 'volumes', label: 'Volumes', icon: CircleStackIcon },
      { id: 'networks', label: 'Networks', icon: GlobeAltIcon },
      { id: 'compose', label: 'Compose', icon: Squares2X2Icon },
    ],
  },
  {
    group: 'ORCHESTRATION',
    items: [{ id: 'kubernetes', label: 'Kubernetes', icon: Squares2X2Icon }],
  },
  {
    group: 'LINUX',
    items: [
      { id: 'machines', label: 'Linux Desktops', icon: ServerStackIcon, count: '2' },
      { id: 'servers', label: 'Linux Servers', icon: CommandLineIcon, count: '1' },
    ],
  },
  {
    group: 'SYSTEM',
    items: [{ id: 'health', label: 'Health', icon: ShieldCheckIcon }],
  },
]

const containerRows = [
  { name: 'web', detail: 'dory-demo / web-api · ghcr.io/augani/web:latest', port: ':3000', cpu: 12.4, memory: '184 MB' },
  { name: 'postgres', detail: 'dory-demo / postgres-db · postgres:17', port: ':5432', cpu: 4.8, memory: '312 MB' },
  { name: 'redis', detail: 'dory-demo / redis-cache · redis:7-alpine', port: ':6379', cpu: 1.9, memory: '42 MB' },
  { name: 'worker', detail: 'dory-demo / worker · ghcr.io/augani/worker:latest', cpu: 8.2, memory: '128 MB' },
]

const podRows = [
  ['web-7f4c9b76d8-k9n2v', 'default', '1/1', 'Running', '0', '18m'],
  ['postgres-0', 'default', '1/1', 'Running', '0', '18m'],
  ['redis-6b8f8cdcd7-wj4pz', 'default', '1/1', 'Running', '0', '18m'],
  ['build-agent-5b9d798f7f-tq8mk', 'agents', '1/1', 'Running', '1', '6m'],
]

function StatusPill({ children, muted = false }: { children: string; muted?: boolean }) {
  return <span className={`demo-status${muted ? ' demo-status-muted' : ''}`}><i />{children}</span>
}

function ContainersDemo({ tick }: { tick: number }) {
  return (
    <div className="demo-content demo-content-containers" key="containers">
      <div className="demo-filterbar">
        <div className="demo-segment"><b>Running</b><span>All</span><span>Stopped</span></div>
        <div className="demo-scope"><b>This context</b><span>All</span></div>
        <StatusPill>4 running</StatusPill>
      </div>
      <div className="demo-compose-row">
        <Squares2X2Icon /><strong>dory-demo</strong><span>4/4 running · 4 shown</span><i /><button type="button">●</button><button type="button">↻</button><button type="button">•••</button>
      </div>
      <div className="demo-container-split">
        <div className="demo-list">
          <div className="demo-table-head demo-container-grid"><span>NAME</span><span>CPU</span><span>MEMORY</span><span /></div>
          {containerRows.map((row, index) => {
            const cpu = Math.max(0.5, row.cpu + ((tick + index * 2) % 5 - 2) * 0.7)
            return (
              <div className={`demo-table-row demo-container-grid${index === 1 ? ' is-selected' : ''}`} key={row.name}>
                <div className="demo-name-cell">
                  <StatusPill>Running</StatusPill>
                  <span><strong>{row.name}</strong>{row.port && <code>{row.port}</code>}<small>{row.detail}</small></span>
                </div>
                <div className="demo-cpu"><i style={{ '--metric': `${Math.min(100, cpu * 3.6)}%` } as CSSProperties} /><span>{cpu.toFixed(1)}%</span></div>
                <span>{row.memory}</span>
                <button type="button" aria-label={`More actions for ${row.name}`}>•••</button>
              </div>
            )
          })}
        </div>
        <div className="demo-detail">
          <div className="demo-detail-head"><div><StatusPill>Running</StatusPill><strong>postgres</strong><small>postgres-db</small></div><button type="button" aria-label="Close details">×</button></div>
          <div className="demo-detail-tabs"><b>Overview</b><span>Stats</span><span>Logs</span><span>Terminal</span><span>Env</span></div>
          <div className="demo-detail-body">
            <div className="demo-detail-hero"><CircleStackIcon /><div><strong>postgres:17</strong><small>Up for 18 minutes</small></div></div>
            <dl>
              <div><dt>DOMAIN</dt><dd>postgres.dory.local</dd></div>
              <div><dt>IP ADDRESS</dt><dd>192.168.127.4</dd></div>
              <div><dt>PORTS</dt><dd>localhost:5432 → 5432</dd></div>
              <div><dt>RESTART POLICY</dt><dd>unless-stopped</dd></div>
            </dl>
            <div className="demo-detail-actions"><button type="button">Restart</button><button type="button">Open terminal</button></div>
          </div>
        </div>
      </div>
    </div>
  )
}

function KubernetesDemo() {
  return (
    <div className="demo-content" key="kubernetes">
      <div className="demo-kube-banner">
        <StatusPill>Cluster Healthy</StatusPill>
        <span>k3s v1.36.2 · 4 pods</span>
        <div className="demo-resource-picker"><b>Pods</b><span>Deployments</span><span>Services</span><span>ConfigMaps</span><span>Secrets</span><span>Ingress</span></div>
        <button type="button">All Namespaces⌄</button>
        <button type="button" className="demo-text-button">Apply YAML</button>
      </div>
      <div className="demo-table-head demo-pod-grid"><span>POD</span><span>NAMESPACE</span><span>READY</span><span>STATUS</span><span>RESTARTS</span><span>AGE</span></div>
      {podRows.map((row) => (
        <div className="demo-table-row demo-pod-grid" key={row[0]}>
          <strong>{row[0]}</strong><span>{row[1]}</span><span>{row[2]}</span><StatusPill>{row[3]}</StatusPill><span>{row[4]}</span><span>{row[5]}</span>
        </div>
      ))}
      <div className="demo-kube-footer"><span><i /> API server reachable</span><code>~/.dory/kube/config</code></div>
    </div>
  )
}

function MachinesDemo({ tick }: { tick: number }) {
  const machines = [
    { name: 'workbench', status: 'Running', cpu: 8.6 + (tick % 4), memory: '2.4 GB', address: '192.168.127.11', shell: 'augustus · /bin/bash', distro: 'Ubuntu 24.04 LTS · Xfce · arm64' },
    { name: 'security-lab', status: 'Stopped', cpu: 0, memory: 'Not running', address: 'security-lab.dory.local', shell: 'analyst · /bin/bash', distro: 'Kali Linux Rolling · Xfce · arm64' },
  ]
  return (
    <div className="demo-content demo-machines" key="machines">
      <div className="demo-machine-grid">
        {machines.map((machine) => (
          <article className="demo-machine-card" key={machine.name}>
            <div className="demo-machine-title">
              <span className="demo-distro-badge">D</span>
              <div><strong>{machine.name}</strong><small>{machine.distro}</small></div>
              <StatusPill muted={machine.status !== 'Running'}>{machine.status}</StatusPill>
              <button type="button" aria-label={`More actions for ${machine.name}`}>•••</button>
            </div>
            <div className="demo-machine-metrics">
              <div><small>CPU</small><strong>{machine.status === 'Running' ? `${machine.cpu.toFixed(1)}%` : 'Off'}</strong></div>
              <div><small>MEMORY</small><strong>{machine.memory}</strong></div>
              <div><small>{machine.status === 'Running' ? 'ADDRESS' : 'DNS NAME'}</small><strong>{machine.address}</strong></div>
            </div>
            <p>{machine.shell}</p>
            <code>$ dory machine shell {machine.name}</code>
            <div className="demo-machine-actions"><button type="button">{machine.status === 'Running' ? '■ Stop' : '▶ Start'}</button><button type="button">Desktop</button><button type="button">⌘ Terminal</button><button type="button">Snapshot</button></div>
          </article>
        ))}
      </div>
      <div className="demo-machine-note"><CircleStackIcon /><span><strong>Retina sharp and persistent</strong>Each desktop has its own display, user, disk, address, resources, shares, and snapshots.</span></div>
    </div>
  )
}

function DoryDemo({ initialView = 'containers', autoCycle = true }: { initialView?: DemoView; autoCycle?: boolean }) {
  const [activeView, setActiveView] = useState<DemoView>(initialView)
  const [paused, setPaused] = useState(false)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    if (!autoCycle || paused || reducedMotion) return
    const timer = window.setInterval(() => {
      setActiveView((current) => demoViews[(demoViews.indexOf(current) + 1) % demoViews.length])
    }, 5200)
    return () => window.clearInterval(timer)
  }, [autoCycle, paused])

  useEffect(() => {
    const timer = window.setInterval(() => setTick((current) => current + 1), 1700)
    return () => window.clearInterval(timer)
  }, [])

  const titles: Record<DemoView, [string, string, string]> = {
    containers: ['Containers', '4 of 5 running', 'New Container'],
    kubernetes: ['Kubernetes', 'Local k3s cluster', 'Apply YAML'],
    machines: ['Linux Desktops', '2 persistent desktops', 'New Desktop'],
  }

  const switchView = (id: string) => {
    if (demoViews.includes(id as DemoView)) setActiveView(id as DemoView)
  }

  return (
    <div
      className="dory-demo"
      aria-label="Interactive preview of the Dory app"
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
    >
      <div className="demo-window-bar">
        <span className="traffic"><i /><i /><i /></span>
        <span>Dory</span>
        <span className="engine-live"><i /> Engine running</span>
      </div>
      <div className="demo-app">
        <aside className="demo-sidebar">
          <div className="demo-brand"><img src="./logo.svg" alt="" /><span><strong>Dory</strong><small>v0.4.2 · Engine running</small></span></div>
          <nav aria-label="Dory preview sections">
            {demoNav.map((group) => (
              <div className="demo-nav-group" key={group.group}>
                <p>{group.group}</p>
                {group.items.map((item) => {
                  const ItemIcon = item.icon
                  return (
                    <button aria-label={item.label} className={item.id === activeView ? 'is-active' : ''} key={item.id} type="button" onClick={() => switchView(item.id)}>
                      <ItemIcon /><span>{item.label}</span>{item.count && <small>{item.count}</small>}
                    </button>
                  )
                })}
              </div>
            ))}
          </nav>
          <div className="demo-meters">
            <div><span>CPU <b>{12 + tick % 5}%</b></span><i><b style={{ width: `${25 + tick % 13}%` }} /></i></div>
            <div><span>Memory <b>3.2 GB</b></span><i><b style={{ width: `${42 + tick % 6}%` }} /></i></div>
          </div>
          <div className="demo-settings"><Cog6ToothIcon /><span>Settings</span><b>◐</b></div>
        </aside>
        <section className="demo-main">
          <header className="demo-toolbar">
            <div><strong>{titles[activeView][0]}</strong><small>{titles[activeView][1]}</small></div>
            <span className="demo-search">⌕ &nbsp; Filter…</span>
            <button type="button">+ &nbsp;{titles[activeView][2]}</button>
          </header>
          {activeView === 'containers' && <ContainersDemo tick={tick} />}
          {activeView === 'kubernetes' && <KubernetesDemo />}
          {activeView === 'machines' && <MachinesDemo tick={tick} />}
        </section>
      </div>
      <div className="demo-live-label"><span /> Live product tour · {titles[activeView][0]}</div>
    </div>
  )
}

function CopyCommand({ command, dark = false }: { command: string; dark?: boolean }) {
  const [copied, setCopied] = useState(false)

  const copy = async () => {
    await navigator.clipboard.writeText(command)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1600)
  }

  return (
    <button className={`copy-command${dark ? ' copy-command-dark' : ''}`} onClick={copy} type="button">
      <CommandLineIcon aria-hidden="true" />
      <code>{command}</code>
      <span aria-live="polite">
        {copied ? <ClipboardDocumentCheckIcon aria-hidden="true" /> : <ClipboardDocumentIcon aria-hidden="true" />}
        {copied ? 'Copied' : 'Copy'}
      </span>
    </button>
  )
}

function App() {
  const [menuOpen, setMenuOpen] = useState(false)
  const [starCount, setStarCount] = useState<number | null>(null)

  useEffect(() => {
    const cacheKey = 'dory.github-stars.v1'
    try {
      const cached = JSON.parse(window.localStorage.getItem(cacheKey) ?? 'null') as { count?: unknown } | null
      if (cached && typeof cached.count === 'number') setStarCount(cached.count)
    } catch {
      window.localStorage.removeItem(cacheKey)
    }

    const controller = new AbortController()
    fetch('https://api.github.com/repos/Augani/dory', {
      headers: { Accept: 'application/vnd.github+json' },
      signal: controller.signal,
    })
      .then((response) => {
        if (!response.ok) throw new Error(`GitHub returned ${response.status}`)
        return response.json() as Promise<{ stargazers_count?: unknown }>
      })
      .then((repository) => {
        if (typeof repository.stargazers_count !== 'number') return
        setStarCount(repository.stargazers_count)
        window.localStorage.setItem(cacheKey, JSON.stringify({ count: repository.stargazers_count }))
      })
      .catch(() => undefined)

    return () => controller.abort()
  }, [])

  const closeMenu = () => setMenuOpen(false)
  const stars = starCount === null ? 'Stars' : starCount.toLocaleString('en-US')

  return (
    <div className="site-shell">
      <header className="nav-wrap">
        <nav className="nav" aria-label="Main navigation">
          <a className="wordmark" href="#top" aria-label="Dory home" onClick={closeMenu}>
            <img src="./logo.svg" alt="" />
            <span>Dory</span>
            <small>0.4.2</small>
          </a>
          <div className={`nav-links${menuOpen ? ' nav-links-open' : ''}`}>
            <a href="#product" onClick={closeMenu}>Product</a>
            <a href="#linux-desktop" onClick={closeMenu}>Linux Desktop</a>
            <a href="#migration" onClick={closeMenu}>Migration</a>
            <a href="#agents" onClick={closeMenu}>Agents</a>
            <a href="#operations" onClick={closeMenu}>Operations</a>
            <a href="#compatibility" onClick={closeMenu}>Compatibility</a>
            <a className="nav-github" href="https://github.com/Augani/dory" onClick={closeMenu} aria-label={`Dory on GitHub, ${stars}`}>
              GitHub <span className="nav-star-count"><StarIcon /> {stars}</span>
            </a>
          </div>
          <a className="nav-cta" href="#download">
            Get Dory <ArrowRightIcon aria-hidden="true" />
          </a>
          <button
            className="menu-button"
            type="button"
            aria-label={menuOpen ? 'Close navigation' : 'Open navigation'}
            aria-expanded={menuOpen}
            onClick={() => setMenuOpen((open) => !open)}
          >
            {menuOpen ? <XMarkIcon aria-hidden="true" /> : <Bars3Icon aria-hidden="true" />}
          </button>
        </nav>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-grid" aria-hidden="true" />
          <div className="hero-glow hero-glow-one" aria-hidden="true" />
          <div className="hero-glow hero-glow-two" aria-hidden="true" />
          <div className="hero-content">
            <div className="release-pill">
              <span /> Dory 0.4.2 · Focused components
              <a href={releaseUrl}>Release notes <ArrowRightIcon /></a>
            </div>
            <p className="hero-kicker">The local Linux workspace for Mac</p>
            <h1>More than containers.<br /><em>Your whole dev machine.</em></h1>
            <p className="hero-lede">
              Docker, Compose, Kubernetes, full Linux desktops, persistent servers, migration, recovery, and agent automation in one native Mac app.
            </p>
            <div className="hero-actions">
              <a className="button button-primary" href="#download">
                <CloudArrowDownIcon /> Choose components first
              </a>
              <a className="button button-ghost" href="#product">
                Explore the product <ArrowRightIcon />
              </a>
            </div>
            <p className="hero-requirements">
              <CheckCircleIcon /> Free and open source
              <span /> macOS 14+
              <span /> No account or telemetry
              <span /> <b className="hero-stars"><StarIcon /> {starCount === null ? 'GitHub stars' : `${stars} GitHub ${starCount === 1 ? 'star' : 'stars'}`}</b>
            </p>
          </div>

          <div className="hero-product" aria-label="Dory app and command line preview">
            <div className="hero-terminal">
              <div className="terminal-bar">
                <span className="traffic"><i /><i /><i /></span>
                <span>~/Projects/app</span>
                <span />
              </div>
              <div className="terminal-body">
                <p><b>$</b> docker compose up -d</p>
                <p className="term-ok">✓ Network app_default created</p>
                <p className="term-ok">✓ Container postgres healthy</p>
                <p className="term-ok">✓ Container api started</p>
                <p><b>$</b> dory routes --json</p>
                <p className="term-json">{'{"domain":"api.dory.local","port":3000}'}</p>
              </div>
            </div>
            <DoryDemo />
            <div className="float-card float-memory"><CpuChipIcon /> Elastic memory</div>
            <div className="float-card float-data"><CircleStackIcon /> One data drive</div>
          </div>
        </section>

        <section className="proof-strip" aria-label="Dory product facts">
          <div><strong>1</strong><span>shared container VM</span></div>
          <div><strong>3</strong><span>managed desktop distributions</span></div>
          <div><strong>11</strong><span>settings areas in the UI</span></div>
          <div><strong>0</strong><span>accounts, telemetry, paid tiers</span></div>
        </section>

        <section className="download-section section" id="download">
          <div className="section-heading centered">
            <p className="eyebrow">Choose before downloading</p>
            <h2>Get the Dory you need.<br /><span>Skip the weight you do not.</span></h2>
            <p>Dory 0.4.2 uses one Docker Core app with signed, removable components. See the exact total before downloading.</p>
          </div>
          <FocusedDownloadSelector />
          <p className="download-release-link">Need ZIP archives, checksums, or SBOMs? <a href={releaseUrl}>View all release assets.</a></p>
        </section>

        <section className="intro section" id="product">
          <div className="section-heading centered">
            <p className="eyebrow">One workspace</p>
            <h2>Everything local development needs.<br /><span>Nothing else to install.</span></h2>
            <p>Dory is the engine, the interface, the Linux layer, and the operating toolkit. Use the app, the commands you know, or a structured agent connection.</p>
          </div>
          <div className="surface-grid">
            {surfaces.map((surface) => {
              const Icon = surface.icon
              return (
                <article className="surface-card" key={surface.label}>
                  <div className="surface-icon"><Icon aria-hidden="true" /></div>
                  <p className="card-label">{surface.label}</p>
                  <h3>{surface.title}</h3>
                  <p>{surface.copy}</p>
                  <ul>
                    {surface.facts.map((fact) => <li key={fact}><CheckCircleIcon /> {fact}</li>)}
                  </ul>
                  <code>{surface.command}</code>
                </article>
              )
            })}
          </div>
        </section>

        <section className="cockpit section">
          <div className="cockpit-copy">
            <p className="eyebrow">Native control room</p>
            <h2>The power is not hidden behind a terminal.</h2>
            <p>Every major workflow and operating setting has a SwiftUI path. Dory stays fast and familiar without shipping a browser runtime.</p>
            <div className="feature-list">
              {cockpitFeatures.map(([title, copy], index) => (
                <div className="feature-row" key={title}>
                  <span>{String(index + 1).padStart(2, '0')}</span>
                  <div><h3>{title}</h3><p>{copy}</p></div>
                </div>
              ))}
            </div>
          </div>
          <div className="cockpit-visual">
            <DoryDemo initialView="kubernetes" />
            <div className="visual-note"><SparklesIcon /> Native SwiftUI. No Electron.</div>
          </div>
        </section>

        <section className="linux-desktop section" id="linux-desktop">
          <div className="desktop-copy">
            <p className="eyebrow eyebrow-light">Focused Linux desktops</p>
            <h2>A real Linux desktop.<br /><span>Native to your Mac.</span></h2>
            <p>Create a managed graphical machine from its own place in the Dory sidebar. Pick the
              distribution, login user, resources, development tools, and only the Mac folders it
              should see. Then open its desktop or terminal without leaving Dory.</p>
            <div className="desktop-distros">
              {desktopDistros.map(([name, version, copy, color]) => (
                <article key={name} style={{ '--distro-color': color } as CSSProperties}>
                  <i>{name.slice(0, 1)}</i>
                  <div><h3>{name}</h3><small>{version} · Xfce · arm64</small><p>{copy}</p></div>
                </article>
              ))}
            </div>
            <div className="desktop-editions">
              <div className="is-featured"><strong>Docker Core</strong><span>The app, engine, Compose, Buildx, migration, and recovery</span></div>
              <div><strong>Desktop packs</strong><span>Add only Debian, Ubuntu, or Kali, then remove each payload independently</span></div>
            </div>
            <a className="text-link light-link" href="#download">Build your focused setup <ArrowRightIcon /></a>
          </div>
          <div className="desktop-product">
            <DoryDemo initialView="machines" autoCycle={false} />
            <div className="desktop-capabilities">
              {desktopCapabilities.map(([title, copy]) => (
                <div key={title}><CheckCircleIcon /><span><strong>{title}</strong>{copy}</span></div>
              ))}
            </div>
          </div>
        </section>

        <section className="migration section" id="migration">
          <div className="migration-shell">
            <div className="migration-copy">
              <p className="eyebrow eyebrow-light">Switch without starting over</p>
              <h2>Bring the work.<br />Leave the lock behind.</h2>
              <p>Dory discovers Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman, and other Docker-compatible sockets. It reads first, checks capacity and collisions, then performs a recoverable import.</p>
              <div className="source-pills">
                {['OrbStack', 'Docker Desktop', 'Colima', 'Rancher Desktop', 'Podman'].map((source) => <span key={source}>{source}</span>)}
              </div>
              <a className="text-link light-link" href="https://github.com/Augani/dory#move-from-another-runtime">Read the migration contract <ArrowRightIcon /></a>
            </div>
            <div className="migration-flow" aria-label="Dory migration flow">
              <div className="flow-step">
                <span>01</span><div><h3>Discover</h3><p>Find running source engines and inventory their data without changing it.</p></div>
              </div>
              <div className="flow-line" />
              <div className="flow-step">
                <span>02</span><div><h3>Preflight</h3><p>Show objects, capacity, collisions, warnings, and the exact copy plan.</p></div>
              </div>
              <div className="flow-line" />
              <div className="flow-step">
                <span>03</span><div><h3>Import and verify</h3><p>Copy transactionally, preserve source data, and keep recovery state.</p></div>
              </div>
            </div>
          </div>
          <div className="migration-objects">
            {migrationObjects.map((item) => <span key={item}><CheckCircleIcon /> {item}</span>)}
          </div>
        </section>

        <section className="foundation section">
          <div className="section-heading">
            <p className="eyebrow">Built to stay understandable</p>
            <h2>Your runtime should explain itself.</h2>
          </div>
          <div className="foundation-grid">
            <article className="foundation-card data-card">
              <CircleStackIcon />
              <p className="card-label">Durable storage</p>
              <h3>One drive. Your location.</h3>
              <p>Images, containers, named volumes, networks, machines, and snapshots stay in one managed `.dorydrive` on local APFS storage.</p>
              <ul>
                <li>Sparse growth from 128 GiB to 2 TiB</li>
                <li>Verified backup and restore</li>
                <li>External local drive support</li>
                <li>Preserved across normal uninstall</li>
              </ul>
              <div className="drive-meter"><span><i /> Physical data</span><strong>Logical ceiling grows when you choose</strong></div>
            </article>
            <article className="foundation-card network-card">
              <GlobeAltIcon />
              <p className="card-label">Mac-aware networking</p>
              <h3>Local by default. Powerful by choice.</h3>
              <p>Ports begin on localhost. Add automatic or custom local names, trusted HTTPS, low ports, or source-preserving LAN access through one visible authorization plan.</p>
              <div className="route-list">
                <code>api.dory.local <span>→</span> :3000</code>
                <code>admin.myproject.local <span>→</span> :80</code>
                <code>host.dory.internal <span>→</span> macOS</code>
                <code>localhost:8080 <span>→</span> container:80</code>
              </div>
            </article>
            <article className="foundation-card idle-card">
              <BoltIcon />
              <p className="card-label">Availability modes</p>
              <h3>Ready when needed. Quiet when not.</h3>
              <p>Choose Always On, Auto-Idle, Battery Saver, or Manual Stop. Dory reports exactly what keeps the engine awake and records sleep and wake history.</p>
              <div className="mode-row"><span className="active">Auto-Idle</span><span>15m</span><span>Ports awake</span></div>
            </article>
            <article className="foundation-card privacy-card">
              <ShieldCheckIcon />
              <p className="card-label">Private by design</p>
              <h3>Local means local.</h3>
              <p>No Dory account, no telemetry, no remote control plane, and no paid commercial-use tier. Sandboxes share no files by default and support bundles are redacted.</p>
              <div className="privacy-facts"><span><LockClosedIcon /> Signed and notarized</span><span><CodeBracketIcon /> GPL-3.0</span></div>
            </article>
          </div>
        </section>

        <section className="agents section" id="agents">
          <div className="agent-grid" aria-hidden="true" />
          <div className="agents-copy">
            <p className="eyebrow eyebrow-light">A runtime agents can operate</p>
            <h2>No screen scraping.<br />No command guessing.</h2>
            <p>Dory publishes a versioned JSON contract, a stdio MCP server, stable schemas, wait primitives, event streams, and a recovery policy built around read-only inspection first.</p>
            <CopyCommand command="dory mcp serve --read-only" dark />
            <div className="agent-links">
              <a href="./llms.txt">llms.txt <ArrowTopRightOnSquareIcon /></a>
              <a href="./llms-full.txt">Full reference <ArrowTopRightOnSquareIcon /></a>
              <a href="./agent-guide.json">Agent JSON <ArrowTopRightOnSquareIcon /></a>
              <a href="./docs/agents.md">MCP guide <ArrowTopRightOnSquareIcon /></a>
            </div>
          </div>
          <div className="agent-console">
            <div className="console-title"><span><i /><i /><i /></span><p>agent-guide.json</p><small>v1</small></div>
            <pre><code>{`{
  "schema": "dev.dory.agent.guide",
  "defaults": {
    "preferJSON": true,
    "nonInteractive": true
  },
  "recommendedRecoveryLoop": [
    "Run doctor before modifying state",
    "Use the matching repair dry run",
    "Apply only when authorized",
    "Re-run the smallest health group"
  ]
}`}</code></pre>
            <div className="tool-cloud">
              {agentTools.map((tool) => <span key={tool}>{tool}</span>)}
            </div>
          </div>
          <div className="sandbox-callout">
            <BeakerIcon />
            <div><p>Policy-enforced agent sandbox</p><span>A dedicated non-root Linux VM per run. Read-only mount defaults, allowlisted egress, credential grants, resource caps, rollback, manifests, kill, and daemon TTL.</span></div>
            <code>dory sandbox run --network none --rollback -- CMD</code>
          </div>
        </section>

        <section className="operations section" id="operations">
          <div className="operations-layout">
            <div className="operations-copy">
              <p className="eyebrow">Recovery without rituals</p>
              <h2>Inspect. Explain. Repair the right thing.</h2>
              <p>Dory exposes nine ordered readiness stages plus attributed memory, FD/thread, guest, disk, watcher-pressure, and owned-network facts. Active probes test the real path, and repairs name their mutation before changing anything.</p>
              <CopyCommand command="dory readiness --json" />
              <a className="text-link" href="./docs/operations.md">Open the operations guide <ArrowRightIcon /></a>
            </div>
            <div className="health-card">
              <div className="health-head">
                <div><span className="health-dot" /><strong>System healthy</strong></div>
                <small>Active probes complete</small>
              </div>
              {[
                ['Docker socket and API', '12 ms'],
                ['Registry and DNS', 'pass'],
                ['Published ports and routes', 'pass'],
                ['Bind mounts and watchers', 'pass'],
                ['Disk and managed drive', 'pass'],
                ['Memory and helper processes', 'pass'],
              ].map(([check, result]) => <div className="health-row" key={check}><CheckCircleIcon /><span>{check}</span><code>{result}</code></div>)}
              <div className="health-actions"><button type="button">Run active probes</button><button type="button">Collect support bundle</button></div>
            </div>
          </div>
          <div className="operation-facts">
            <div><WrenchScrewdriverIcon /><h3>Targeted repair</h3><p>Reconnect the agent, replace only the socket forwarder, restart dockerd in place, reconcile routes, or revalidate the drive.</p></div>
            <div><ShieldCheckIcon /><h3>Data-plane safe</h3><p>Broad repair does not restart running workloads without explicit restart intent.</p></div>
            <div><CircleStackIcon /><h3>Safe cleanup</h3><p>Dry run by default. Volumes require an additional explicit flag.</p></div>
            <div><ArrowsRightLeftIcon /><h3>Wait and events</h3><p>Use stable schemas instead of custom polling and terminal text parsing.</p></div>
          </div>
        </section>

        <section className="settings-section section">
          <div className="section-heading centered">
            <p className="eyebrow">Every setting has a home</p>
            <h2>Power for terminal users.<br /><span>Control for everyone else.</span></h2>
          </div>
          <div className="settings-grid">
            {settings.map(([title, copy], index) => (
              <div className="setting-card" key={title}>
                <span>{String(index + 1).padStart(2, '0')}</span><div><h3>{title}</h3><p>{copy}</p></div>
              </div>
            ))}
          </div>
        </section>

        <section className="truth section" id="compatibility">
          <div className="truth-copy">
            <p className="eyebrow">Clear release boundaries</p>
            <h2>Know what is ready before you depend on it.</h2>
            <p>Dory labels every public capability supported, preview with its exact limit, or unavailable. The app, README, agent guide, architecture, and compatibility contract use the same language.</p>
            <a className="text-link" href="./docs/compatibility.md">Read the compatibility contract <ArrowRightIcon /></a>
          </div>
          <div className="state-table">
            {releaseStates.map(([state, copy]) => (
              <div className={`state-row state-${state.toLowerCase()}`} key={state}><span>{state}</span><p>{copy}</p></div>
            ))}
          </div>
        </section>

        <section className="faq section">
          <div className="section-heading">
            <p className="eyebrow">Good questions, direct answers</p>
            <h2>What changes when you choose Dory?</h2>
          </div>
          <div className="faq-grid">
            {faqs.map((faq) => (
              <details key={faq.question}>
                <summary>{faq.question}<span>+</span></summary>
                <p>{faq.answer}</p>
              </details>
            ))}
          </div>
        </section>

        <section className="install-section">
          <div className="install-orbit" aria-hidden="true" />
          <img src="./logo.svg" alt="" />
          <p className="eyebrow eyebrow-light">Start local. Stay in control.</p>
          <h2>Bring your whole Linux workspace home to Mac.</h2>
          <p>Free, open source, signed, and notarized. Homebrew installs Docker Core. Add only the signed components you need from Dory.</p>
          <CopyCommand command={installCommand} dark />
          <div className="install-actions">
            <a className="button button-white" href="#download">Choose your components <ArrowRightIcon /></a>
            <a href="https://github.com/Augani/dory">View source on GitHub <ArrowTopRightOnSquareIcon /></a>
          </div>
        </section>
      </main>

      <footer>
        <div className="footer-brand">
          <a className="wordmark" href="#top"><img src="./logo.svg" alt="" /><span>Dory</span></a>
          <p>Your complete local Linux workspace, built for Mac.</p>
        </div>
        <div className="footer-links">
          <div><strong>Product</strong><a href="#product">Overview</a><a href="#migration">Migration</a><a href="#agents">Agents</a><a href="#operations">Operations</a></div>
          <div><strong>Docs</strong><a href="./llms-full.txt">Agent reference</a><a href="./docs/agents.md">MCP guide</a><a href="./docs/architecture.md">Architecture</a><a href="./docs/performance.md">Performance evidence</a><a href="./docs/compatibility.md">Compatibility</a></div>
          <div><strong>Project</strong><a href="https://github.com/Augani/dory">GitHub</a><a href="https://github.com/Augani/dory/releases/latest">Releases</a><a href="https://github.com/Augani/dory/issues">Issues</a><a href="https://github.com/Augani/dory/blob/main/LICENSE">GPL-3.0</a></div>
        </div>
        <div className="footer-bottom"><span>© 2026 Dory contributors</span><span>Apple Silicon first. Intel support later.</span></div>
      </footer>
    </div>
  )
}

export default App

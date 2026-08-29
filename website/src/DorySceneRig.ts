import * as THREE from 'three'

type RigOptions = {
  compact: boolean
  random: () => number
  chapterCount: number
}

type RigUpdate = {
  time: number
  phase: number
  pulse: number
  reducedMotion: boolean
}

type LabelOptions = {
  width?: number
  accent?: string
  background?: string
  color?: string
  border?: string
  fontSize?: number
}

const BLUE = 0x70c7ff
const ICE = 0xd9e8f2
const STEEL = 0x658097
const DIM = 0x2f4355
const GREEN = 0x74e3ad
const AMBER = 0xf4b85d

function makeLabel(text: string, options: LabelOptions = {}) {
  const canvas = document.createElement('canvas')
  canvas.width = 512
  canvas.height = 112
  const context = canvas.getContext('2d')!
  const background = options.background ?? 'rgba(6, 13, 19, 0.88)'
  const border = options.border ?? 'rgba(151, 200, 232, 0.28)'
  const accent = options.accent ?? '#70c7ff'
  const color = options.color ?? '#eef7fc'
  const fontSize = options.fontSize ?? (text.length > 22 ? 23 : text.length > 15 ? 27 : 31)

  context.clearRect(0, 0, canvas.width, canvas.height)
  context.fillStyle = background
  context.fillRect(1, 1, canvas.width - 2, canvas.height - 2)
  context.strokeStyle = border
  context.lineWidth = 2
  context.strokeRect(2, 2, canvas.width - 4, canvas.height - 4)
  context.fillStyle = accent
  context.fillRect(0, 0, 9, canvas.height)
  context.fillStyle = color
  context.font = `600 ${fontSize}px Inter, -apple-system, BlinkMacSystemFont, sans-serif`
  context.textBaseline = 'middle'
  context.fillText(text.toUpperCase(), 31, canvas.height / 2 + 1, canvas.width - 48)

  const texture = new THREE.CanvasTexture(canvas)
  texture.colorSpace = THREE.SRGBColorSpace
  texture.minFilter = THREE.LinearFilter
  texture.magFilter = THREE.LinearFilter
  const material = new THREE.SpriteMaterial({ map: texture, transparent: true, depthTest: false })
  const sprite = new THREE.Sprite(material)
  const width = options.width ?? 2.4
  sprite.scale.set(width, width * (canvas.height / canvas.width), 1)
  sprite.renderOrder = 50
  return sprite
}

function addLabel(parent: THREE.Group, text: string, position: [number, number, number], options?: LabelOptions) {
  const label = makeLabel(text, options)
  label.position.set(...position)
  parent.add(label)
  return label
}

function addLine(parent: THREE.Group, start: THREE.Vector3, end: THREE.Vector3, color = BLUE, opacity = 0.6) {
  const geometry = new THREE.BufferGeometry().setFromPoints([start, end])
  const line = new THREE.Line(geometry, new THREE.LineBasicMaterial({ color, transparent: true, opacity }))
  parent.add(line)
  return line
}

function addWireBox(parent: THREE.Group, position: THREE.Vector3, size: THREE.Vector3, color = BLUE, opacity = 0.55) {
  const source = new THREE.BoxGeometry(size.x, size.y, size.z)
  const geometry = new THREE.EdgesGeometry(source)
  source.dispose()
  const line = new THREE.LineSegments(geometry, new THREE.LineBasicMaterial({ color, transparent: true, opacity }))
  line.position.copy(position)
  parent.add(line)
  return line
}

function addBlock(parent: THREE.Group, position: [number, number, number], size: [number, number, number], color: number, emissive = 0x0b1c28) {
  const material = new THREE.MeshStandardMaterial({
    color,
    emissive,
    emissiveIntensity: 0.28,
    roughness: 0.28,
    metalness: 0.64,
    transparent: true,
  })
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material)
  mesh.position.set(...position)
  parent.add(mesh)
  return mesh
}

function addPanel(parent: THREE.Group, position: [number, number, number], size: [number, number], color = 0x102331) {
  const material = new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.14, roughness: 0.48, metalness: 0.4, transparent: true, opacity: 0.92 })
  const panel = new THREE.Mesh(new THREE.BoxGeometry(size[0], size[1], 0.13), material)
  panel.position.set(...position)
  parent.add(panel)
  addWireBox(parent, new THREE.Vector3(...position), new THREE.Vector3(size[0] + 0.06, size[1] + 0.06, 0.19), BLUE, 0.38)
  return panel
}

function addPacket(parent: THREE.Group, color = BLUE, radius = 0.075) {
  const packet = new THREE.Mesh(
    new THREE.SphereGeometry(radius, 12, 8),
    new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.95 }),
  )
  parent.add(packet)
  return packet
}

function setAlong(packet: THREE.Object3D, start: THREE.Vector3, end: THREE.Vector3, progress: number) {
  packet.position.lerpVectors(start, end, progress)
}

export function createDorySceneRig({ compact, random, chapterCount }: RigOptions) {
  const groups = Array.from({ length: chapterCount }, () => new THREE.Group())
  const sceneOffset = compact ? 0 : 3.75
  groups.forEach((group, index) => {
    group.position.set(compact ? 0 : (index % 2 === 0 ? sceneOffset : -sceneOffset), compact ? 2.3 : 0, 0)
    if (compact) group.scale.setScalar(0.78)
  })

  const cameraFrames = groups.map(() => ({
    position: [0, compact ? 0 : 0.42, compact ? 13.8 : 12.8],
    target: [0, 0, 0],
  }))

  // 01 — A single owned stack, visibly connected from app to data plane.
  const system = groups[0]
  addWireBox(system, new THREE.Vector3(0, 0, -0.15), new THREE.Vector3(5.5, 5.8, 1.15), DIM, 0.42)
  addLabel(system, 'ONE DEVELOPMENT COMPUTER', [0, 3.25, 0.45], { width: 3.7 })
  const systemLayers: THREE.Mesh[] = []
  const systemLayerNames = ['DORY APP', 'DORYD CONTROL PLANE', 'ARM64 VM', 'GUEST AGENT', 'DATA + NETWORK']
  systemLayerNames.forEach((name, index) => {
    const y = 2.08 - index * 1.02
    const layer = addBlock(system, [0, y, 0], [4.55 - index * 0.2, 0.62, 0.58], index === 0 ? ICE : index === 2 ? 0x4fa7dd : STEEL)
    systemLayers.push(layer)
    addLabel(system, name, [0, y, 0.5], { width: 2.65 - index * 0.05, fontSize: 24 })
    if (index < systemLayerNames.length - 1) addLine(system, new THREE.Vector3(0, y - 0.34, 0.2), new THREE.Vector3(0, y - 0.69, 0.2), BLUE, 0.74)
  })
  const systemPulse = addPacket(system, BLUE, 0.105)
  systemPulse.position.z = 0.55
  const readinessDots: THREE.Mesh[] = []
  for (let index = 0; index < 9; index += 1) {
    const dot = new THREE.Mesh(
      new THREE.SphereGeometry(0.075, 10, 8),
      new THREE.MeshStandardMaterial({ color: index < 7 ? BLUE : 0x7890a2, emissive: BLUE, emissiveIntensity: index < 7 ? 1.4 : 0.12, transparent: true }),
    )
    dot.position.set(-1.6 + index * 0.4, -2.55, 0.4)
    readinessDots.push(dot)
    system.add(dot)
  }
  addLabel(system, '9 OWNED READINESS GATES', [0, -3.08, 0.42], { width: 3.2, fontSize: 23 })

  // 02 — One engine with three visibly distinct product surfaces.
  const platform = groups[1]
  const engine = addBlock(platform, [0, 0, 0], [1.55, 1.55, 1.55], 0x3187ba)
  addWireBox(platform, new THREE.Vector3(0, 0, 0), new THREE.Vector3(1.8, 1.8, 1.8), BLUE, 0.78)
  addLabel(platform, 'DORY ENGINE', [0, -1.15, 0.65], { width: 2.1 })
  const engineRing = new THREE.Mesh(new THREE.TorusGeometry(1.22, 0.035, 8, 84), new THREE.MeshBasicMaterial({ color: BLUE, transparent: true, opacity: 0.72 }))
  engineRing.rotation.x = Math.PI / 2
  platform.add(engineRing)

  const dockerGroup = new THREE.Group()
  dockerGroup.position.set(-2.65, 0.25, 0)
  platform.add(dockerGroup)
  addWireBox(dockerGroup, new THREE.Vector3(), new THREE.Vector3(2.15, 2.55, 1.3), STEEL, 0.58)
  ;[['api', -0.52, 0.62], ['db', 0.5, 0.62], ['worker', 0, -0.48]].forEach(([name, x, y], index) => {
    const node = addBlock(dockerGroup, [Number(x), Number(y), 0], [0.72, 0.72, 0.72], index === 0 ? 0x55b6e8 : ICE)
    node.rotation.y = index * 0.35
    addLabel(dockerGroup, String(name), [Number(x), Number(y), 0.55], { width: 0.74, fontSize: 25 })
  })
  addLabel(dockerGroup, 'DOCKER + COMPOSE', [0, 1.62, 0.35], { width: 2.25 })

  const kubernetes = new THREE.Group()
  kubernetes.position.set(2.65, 0.25, 0)
  platform.add(kubernetes)
  addWireBox(kubernetes, new THREE.Vector3(), new THREE.Vector3(2.2, 2.55, 1.3), BLUE, 0.63)
  const kubeNodes: THREE.Mesh[] = []
  ;[[-0.52, 0.5], [0.52, 0.5], [-0.52, -0.5], [0.52, -0.5]].forEach(([x, y], index) => {
    const node = new THREE.Mesh(
      new THREE.OctahedronGeometry(0.3, 0),
      new THREE.MeshStandardMaterial({ color: index === 0 ? BLUE : STEEL, emissive: BLUE, emissiveIntensity: index === 0 ? 0.8 : 0.15, transparent: true }),
    )
    node.position.set(x, y, 0)
    kubeNodes.push(node)
    kubernetes.add(node)
  })
  addLabel(kubernetes, 'K3S CLUSTER', [0, 1.62, 0.35], { width: 1.95 })
  addLabel(kubernetes, 'SEPARATE IMAGE STORE', [0, -1.62, 0.35], { width: 2.25, accent: '#9fb2c1' })

  const linuxScreen = addPanel(platform, [0, 2.4, -0.15], [2.55, 1.15], 0x0d2535)
  addLabel(platform, 'LINUX ARM64 MACHINE', [0, 2.42, 0.32], { width: 2.25 })
  for (let index = 0; index < 4; index += 1) {
    const line = addBlock(platform, [-0.55 + index * 0.12, 2.18 - index * 0.16, 0.06], [1.08 + index * 0.12, 0.035, 0.025], index === 0 ? BLUE : STEEL)
    line.rotation.z = 0
  }
  addLine(platform, new THREE.Vector3(-1.7, 0.25, 0.2), new THREE.Vector3(-0.92, 0.08, 0.2), BLUE, 0.68)
  addLine(platform, new THREE.Vector3(0.92, 0.08, 0.2), new THREE.Vector3(1.7, 0.25, 0.2), BLUE, 0.68)
  addLine(platform, new THREE.Vector3(0, 0.92, 0.2), new THREE.Vector3(0, 1.76, 0.2), BLUE, 0.68)
  const platformPackets = [addPacket(platform), addPacket(platform), addPacket(platform)]

  // 03 — Project detection enters a scanner and exits as sealed VM sandboxes.
  const agents = groups[2]
  addLabel(agents, 'PROJECT DETECTION → RUNTIME → POLICY', [0, 3.05, 0.4], { width: 4.2 })
  const manifests = ['package.json', 'pyproject.toml', 'go.mod']
  manifests.forEach((name, index) => {
    const y = 1.55 - index * 1.1
    addPanel(agents, [-3.0, y, 0], [1.75, 0.68], 0x12212c)
    addLabel(agents, name, [-3.0, y, 0.3], { width: 1.55, accent: '#9fb2c1', fontSize: 23 })
    addLine(agents, new THREE.Vector3(-2.1, y, 0.08), new THREE.Vector3(-1.35, 0.5 - index * 0.5, 0.08), BLUE, 0.48)
  })
  addWireBox(agents, new THREE.Vector3(-0.8, 0.4, 0), new THREE.Vector3(0.55, 4.1, 1.15), BLUE, 0.8)
  const scannerBeam = addBlock(agents, [-0.8, 0.4, 0], [0.66, 0.08, 1.18], BLUE, BLUE)
  addLabel(agents, 'DETECT', [-0.8, -2.05, 0.42], { width: 1.2 })
  const runtimeLabels = ['NODE 22', 'PYTHON 3.13', 'GO']
  const sandboxShells: THREE.LineSegments[] = []
  const sandboxCores: THREE.Mesh[] = []
  runtimeLabels.forEach((runtime, index) => {
    const y = 1.5 - index * 1.5
    const shell = addWireBox(agents, new THREE.Vector3(2.0, y, 0), new THREE.Vector3(2.55, 1.12, 1.35), index === 0 ? BLUE : STEEL, 0.75)
    sandboxShells.push(shell)
    const core = addBlock(agents, [1.62, y, 0], [0.42, 0.42, 0.42], index === 0 ? BLUE : ICE)
    sandboxCores.push(core)
    addLabel(agents, runtime, [2.25, y + 0.2, 0.74], { width: 1.65, fontSize: 22 })
    addLabel(agents, index === 0 ? 'NON-ROOT · NET:NONE' : index === 1 ? 'READ-ONLY · TTL' : 'RESET BASELINE', [2.25, y - 0.26, 0.74], { width: 1.75, accent: '#77e1ad', fontSize: 19 })
    addLine(agents, new THREE.Vector3(-0.5, 0.45 - index * 0.35, 0.08), new THREE.Vector3(0.72, y, 0.08), BLUE, 0.55)
  })
  const agentPacket = addPacket(agents, GREEN, 0.11)

  // 04 — A protected working set inside guest RAM, with pages returning to the host.
  const memory = groups[3]
  addWireBox(memory, new THREE.Vector3(0, 0, -0.2), new THREE.Vector3(6.8, 5.4, 1.4), STEEL, 0.38)
  addLabel(memory, 'macOS HOST · PRESSURE SAMPLED', [0, 3.05, 0.45], { width: 3.75 })
  const guestBalloon = new THREE.Mesh(
    new THREE.SphereGeometry(1.78, 36, 28),
    new THREE.MeshStandardMaterial({ color: 0x1a5b82, emissive: 0x0c3c58, emissiveIntensity: 0.45, roughness: 0.18, metalness: 0.45, transparent: true, opacity: 0.5, wireframe: true }),
  )
  guestBalloon.position.x = -1.55
  memory.add(guestBalloon)
  const workingSet = new THREE.Mesh(
    new THREE.IcosahedronGeometry(0.92, 2),
    new THREE.MeshStandardMaterial({ color: ICE, emissive: BLUE, emissiveIntensity: 0.5, roughness: 0.2, metalness: 0.62, transparent: true }),
  )
  workingSet.position.x = -1.55
  memory.add(workingSet)
  addLabel(memory, 'GUEST RAM · PSI', [-1.55, 2.2, 0.5], { width: 2.1 })
  addLabel(memory, 'PROTECTED WORKING SET', [-1.55, -2.2, 0.5], { width: 2.45, accent: '#eaf6ff' })
  addLabel(memory, 'RECLAIMABLE PAGES → HOST', [2.05, 1.42, 0.5], { width: 2.75 })
  addLabel(memory, 'BOUNDED 256 / 512 MiB STEPS', [2.05, -1.62, 0.5], { width: 2.9, accent: '#9fb2c1', fontSize: 21 })
  const gaugeTrack = addBlock(memory, [2.05, 0.36, 0], [2.8, 0.18, 0.22], DIM)
  const gaugeFill = addBlock(memory, [1.15, 0.36, 0.16], [1.0, 0.22, 0.25], BLUE, BLUE)
  addLabel(memory, 'HOST AVAILABLE', [2.05, -0.15, 0.42], { width: 1.8, fontSize: 22 })
  const pageCount = compact ? 90 : 170
  const pageStart: THREE.Vector3[] = []
  const pageTarget: THREE.Vector3[] = []
  const pagePositions = new Float32Array(pageCount * 3)
  for (let index = 0; index < pageCount; index += 1) {
    const radius = 1.05 + random() * 0.62
    const theta = random() * Math.PI * 2
    const phi = Math.acos(2 * random() - 1)
    const start = new THREE.Vector3(
      -1.55 + radius * Math.sin(phi) * Math.cos(theta),
      radius * Math.cos(phi),
      radius * Math.sin(phi) * Math.sin(theta),
    )
    const target = new THREE.Vector3(0.5 + random() * 3.2, -0.85 + random() * 2.2, -0.35 + random() * 0.7)
    pageStart.push(start)
    pageTarget.push(target)
    pagePositions.set(start.toArray(), index * 3)
  }
  const pageGeometry = new THREE.BufferGeometry()
  pageGeometry.setAttribute('position', new THREE.BufferAttribute(pagePositions, 3))
  const memoryPages = new THREE.Points(pageGeometry, new THREE.PointsMaterial({ color: 0xa7ddff, size: compact ? 0.055 : 0.075, transparent: true, opacity: 0.78, depthWrite: false }))
  memory.add(memoryPages)

  // 05 — A sleeping engine leaves a socket beacon and a literal readiness path.
  const idle = groups[4]
  addLabel(idle, 'AUTO-IDLE 5 · 15 · 30 · 60 MIN', [0, 3.0, 0.45], { width: 3.8 })
  addPanel(idle, [-3.25, 1.1, 0], [1.55, 0.74], 0x132331)
  addLabel(idle, 'docker ps', [-3.25, 1.1, 0.34], { width: 1.25, accent: '#d9e8f2' })
  const socket = new THREE.Mesh(
    new THREE.TorusGeometry(0.48, 0.11, 10, 48),
    new THREE.MeshStandardMaterial({ color: BLUE, emissive: BLUE, emissiveIntensity: 1.6, roughness: 0.18, metalness: 0.7, transparent: true }),
  )
  socket.position.set(-3.2, -0.35, 0)
  idle.add(socket)
  addLabel(idle, 'DORY.SOCK · LISTENING', [-3.2, -1.15, 0.4], { width: 2.2 })
  const engineParts: THREE.Mesh[] = []
  for (let index = 0; index < 5; index += 1) {
    const part = addBlock(idle, [3.28 + (index % 2) * 0.5, 0.6 - Math.floor(index / 2) * 0.58, 0], [0.42, 0.42, 0.42], index === 0 ? BLUE : STEEL)
    engineParts.push(part)
  }
  addWireBox(idle, new THREE.Vector3(3.5, 0, 0), new THREE.Vector3(1.75, 2.55, 1.25), STEEL, 0.55)
  addLabel(idle, 'ENGINE · SLEEP → READY', [3.5, -1.72, 0.45], { width: 2.35 })
  const gateNames = ['APP', 'DORYD', 'VM', 'AGENT', 'DATA', 'NET', 'DOCKER', 'HOST', 'K3S']
  const wakeGates: THREE.Mesh<THREE.BoxGeometry, THREE.MeshStandardMaterial>[] = []
  gateNames.forEach((name, index) => {
    const x = -1.92 + index * 0.56
    const gate = addBlock(idle, [x, 0, 0], [0.08, 1.5, 0.35], DIM, BLUE) as THREE.Mesh<THREE.BoxGeometry, THREE.MeshStandardMaterial>
    wakeGates.push(gate)
    addLabel(idle, name, [x, -1.12, 0.38], { width: 0.62, fontSize: 18, accent: index < 7 ? '#70c7ff' : '#9fb2c1' })
  })
  addLine(idle, new THREE.Vector3(-3.2, 0.55, 0), new THREE.Vector3(-2.28, 0, 0), BLUE, 0.66)
  addLine(idle, new THREE.Vector3(2.58, 0, 0), new THREE.Vector3(3.05, 0, 0), BLUE, 0.66)
  const wakePacket = addPacket(idle, GREEN, 0.105)

  // 06 — Network ownership above, verified data return below.
  const recovery = groups[5]
  addLabel(recovery, 'OWNED ROUTE', [0, 3.02, 0.45], { width: 2.0 })
  const routePositions = [-2.8, 0, 2.8]
  const routeLabels = ['HTTPS://API.DORY.LOCAL', 'TLS + DORY ROUTE', 'API :3000']
  routePositions.forEach((x, index) => {
    addPanel(recovery, [x, 1.82, 0], [2.12, 0.82], index === 1 ? 0x16496a : 0x12212c)
    addLabel(recovery, routeLabels[index], [x, 1.82, 0.36], { width: 1.88, accent: index === 1 ? '#70c7ff' : '#d9e8f2', fontSize: 20 })
    if (index < 2) addLine(recovery, new THREE.Vector3(x + 1.08, 1.82, 0.05), new THREE.Vector3(routePositions[index + 1] - 1.08, 1.82, 0.05), BLUE, 0.72)
  })
  addLabel(recovery, 'LOCALHOST DEFAULT · LAN/VPN OPT-IN', [0, 1.03, 0.42], { width: 3.4, accent: '#9fb2c1', fontSize: 21 })
  const routePacket = addPacket(recovery, GREEN, 0.095)

  const drive = new THREE.Mesh(
    new THREE.OctahedronGeometry(0.9, 1),
    new THREE.MeshStandardMaterial({ color: 0x4ca9dc, emissive: 0x164d6d, emissiveIntensity: 0.65, roughness: 0.2, metalness: 0.64, transparent: true }),
  )
  drive.position.set(-2.65, -1.35, 0)
  recovery.add(drive)
  addLabel(recovery, 'DORY DRIVE', [-2.65, -2.62, 0.42], { width: 1.65 })
  const chunkBlocks: THREE.Mesh[] = []
  for (let index = 0; index < 6; index += 1) {
    const block = addBlock(recovery, [-0.72 + (index % 3) * 0.72, -1.1 - Math.floor(index / 3) * 0.52, 0], [0.56, 0.34, 0.4], index < 5 ? STEEL : BLUE)
    chunkBlocks.push(block)
  }
  addLabel(recovery, '8 MiB HASHED CHUNKS', [0, -2.62, 0.42], { width: 2.2, accent: '#9fb2c1' })
  const restored = new THREE.Mesh(
    new THREE.OctahedronGeometry(0.9, 1),
    new THREE.MeshStandardMaterial({ color: GREEN, emissive: GREEN, emissiveIntensity: 0.7, roughness: 0.2, metalness: 0.58, transparent: true }),
  )
  restored.position.set(2.65, -1.35, 0)
  recovery.add(restored)
  addLabel(recovery, 'RESTORED · VERIFIED ✓', [2.65, -2.62, 0.42], { width: 2.3, accent: '#74e3ad' })
  addLine(recovery, new THREE.Vector3(-1.75, -1.35, 0.05), new THREE.Vector3(-1.15, -1.35, 0.05), BLUE, 0.68)
  addLine(recovery, new THREE.Vector3(1.15, -1.35, 0.05), new THREE.Vector3(1.75, -1.35, 0.05), GREEN, 0.72)
  const backupPacket = addPacket(recovery, GREEN, 0.1)

  // 07 — Four explicit availability portals, not three anonymous frames.
  const horizons = groups[6]
  addLabel(horizons, 'ONE CONTROL MODEL · DIFFERENT BACKENDS', [0, 3.08, 0.45], { width: 4.1 })
  const portalSpecs = [
    { x: -2.05, y: 1.25, title: 'MANAGED LINUX ARM64', status: 'SUPPORTED', color: BLUE, active: true },
    { x: 2.05, y: 1.25, title: 'CUSTOM ARM64 ISO', status: 'PREVIEW', color: AMBER, active: true },
    { x: -2.05, y: -1.45, title: 'WINDOWS ARM', status: 'DEFERRED', color: STEEL, active: false },
    { x: 2.05, y: -1.45, title: 'macOS GUEST', status: 'DEFERRED', color: STEEL, active: false },
  ]
  const portalScreens: THREE.Mesh[] = []
  portalSpecs.forEach((spec, index) => {
    const panel = addPanel(horizons, [spec.x, spec.y, 0], [3.35, 1.95], spec.active ? (index === 0 ? 0x123e58 : 0x3c2d18) : 0x0d151c)
    portalScreens.push(panel)
    addLabel(horizons, spec.title, [spec.x, spec.y + 0.38, 0.36], { width: 2.55, accent: `#${spec.color.toString(16).padStart(6, '0')}`, fontSize: 22 })
    addLabel(horizons, spec.status, [spec.x, spec.y - 0.42, 0.36], {
      width: 1.45,
      accent: `#${spec.color.toString(16).padStart(6, '0')}`,
      background: spec.active ? 'rgba(7, 23, 32, 0.9)' : 'rgba(8, 12, 16, 0.92)',
      fontSize: 23,
    })
    if (!spec.active) {
      addLine(horizons, new THREE.Vector3(spec.x - 1.15, spec.y - 0.7, 0.28), new THREE.Vector3(spec.x + 1.15, spec.y + 0.7, 0.28), STEEL, 0.42)
      addLine(horizons, new THREE.Vector3(spec.x - 1.15, spec.y + 0.7, 0.28), new THREE.Vector3(spec.x + 1.15, spec.y - 0.7, 0.28), STEEL, 0.42)
    }
  })
  const isoScan = addBlock(horizons, [2.05, 1.25, 0.38], [2.65, 0.045, 0.08], AMBER, AMBER)

  const platformStarts = [new THREE.Vector3(-1.68, 0.25, 0.2), new THREE.Vector3(0.92, 0.08, 0.2), new THREE.Vector3(0, 0.92, 0.2)]
  const platformEnds = [new THREE.Vector3(-0.92, 0.08, 0.2), new THREE.Vector3(1.68, 0.25, 0.2), new THREE.Vector3(0, 1.76, 0.2)]

  const update = ({ time, phase, pulse, reducedMotion }: RigUpdate) => {
    const elapsed = time * 0.001
    const motion = reducedMotion ? 0 : 1

    const stackProgress = reducedMotion ? 0.55 : (elapsed * 0.23 + pulse * 0.55) % 1
    systemPulse.position.y = THREE.MathUtils.lerp(2.08, -2.08, stackProgress)
    systemLayers.forEach((layer, index) => {
      const material = layer.material as THREE.MeshStandardMaterial
      const active = Math.abs(stackProgress * (systemLayers.length - 1) - index) < 0.65
      material.emissiveIntensity = active ? 1.25 : 0.22
    })
    readinessDots.forEach((dot, index) => {
      const material = dot.material as THREE.MeshStandardMaterial
      material.emissiveIntensity = index / readinessDots.length < stackProgress ? 1.8 : 0.1
    })

    engine.rotation.y = elapsed * 0.18 * motion
    engineRing.rotation.z = elapsed * 0.22 * motion
    kubeNodes.forEach((node, index) => { node.rotation.y = elapsed * (0.28 + index * 0.04) * motion })
    platformPackets.forEach((packet, index) => {
      const travel = reducedMotion ? 0.55 : (elapsed * 0.36 + index * 0.31 + pulse * 0.35) % 1
      setAlong(packet, platformStarts[index], platformEnds[index], travel)
    })
    linuxScreen.rotation.y = Math.sin(elapsed * 0.25) * 0.025 * motion

    scannerBeam.position.y = 0.4 + Math.sin(elapsed * 1.35) * 1.72 * motion
    sandboxShells.forEach((shell, index) => { shell.rotation.y = Math.sin(elapsed * 0.42 + index) * 0.06 * motion })
    sandboxCores.forEach((core, index) => {
      const scale = 1 + Math.max(0, Math.sin(elapsed * 1.8 - index * 0.65 + pulse * 2)) * 0.17 * motion
      core.scale.setScalar(scale)
    })
    const agentTravel = reducedMotion ? 0.72 : (elapsed * 0.22 + pulse * 0.65) % 1
    if (agentTravel < 0.5) setAlong(agentPacket, new THREE.Vector3(-3, 1.55, 0.45), new THREE.Vector3(-0.8, 0.4, 0.45), agentTravel * 2)
    else setAlong(agentPacket, new THREE.Vector3(-0.8, 0.4, 0.45), new THREE.Vector3(2, 1.5, 0.45), (agentTravel - 0.5) * 2)

    const reclaimBase = THREE.MathUtils.clamp((phase - 2.68) * 1.28, 0.18, 0.86)
    const reclaim = THREE.MathUtils.clamp(reclaimBase + pulse * 0.34, 0, 1)
    const pageAttribute = pageGeometry.getAttribute('position') as THREE.BufferAttribute
    for (let index = 0; index < pageCount; index += 1) {
      const cadence = THREE.MathUtils.clamp(reclaim * 1.35 - (index % 17) / 25, 0, 1)
      const wobble = Math.sin(elapsed * 1.2 + index) * 0.025 * motion
      pageAttribute.setXYZ(
        index,
        THREE.MathUtils.lerp(pageStart[index].x, pageTarget[index].x, cadence),
        THREE.MathUtils.lerp(pageStart[index].y, pageTarget[index].y, cadence) + wobble,
        THREE.MathUtils.lerp(pageStart[index].z, pageTarget[index].z, cadence),
      )
    }
    pageAttribute.needsUpdate = true
    guestBalloon.scale.setScalar(1 - reclaim * 0.13)
    workingSet.scale.setScalar(1 + pulse * 0.11)
    gaugeFill.scale.x = 0.55 + reclaim * 1.15
    gaugeFill.position.x = 0.75 + gaugeFill.scale.x * 0.36
    gaugeTrack.rotation.z = 0

    const wakeCycle = reducedMotion ? 0.72 : (elapsed * 0.115 + pulse * 0.72) % 1
    socket.scale.setScalar(1 + Math.sin(elapsed * 2.1) * 0.09 * motion + pulse * 0.18)
    wakeGates.forEach((gate, index) => {
      const gateOn = wakeCycle * wakeGates.length > index
      gate.material.emissiveIntensity = gateOn ? 2.2 : 0.08
      gate.material.color.setHex(gateOn ? BLUE : DIM)
    })
    if (wakeCycle < 0.18) setAlong(wakePacket, new THREE.Vector3(-3.25, 0.72, 0.4), new THREE.Vector3(-3.2, -0.35, 0.4), wakeCycle / 0.18)
    else setAlong(wakePacket, new THREE.Vector3(-2.95, 0, 0.4), new THREE.Vector3(3.05, 0, 0.4), (wakeCycle - 0.18) / 0.82)
    engineParts.forEach((part, index) => {
      const ready = THREE.MathUtils.smoothstep(wakeCycle, 0.65 + index * 0.025, 0.94)
      const material = part.material as THREE.MeshStandardMaterial
      material.emissiveIntensity = 0.12 + ready * 1.25
      part.scale.setScalar(0.78 + ready * 0.22)
    })

    const routeTravel = reducedMotion ? 0.6 : (elapsed * 0.2 + pulse * 0.7) % 1
    if (routeTravel < 0.5) setAlong(routePacket, new THREE.Vector3(-2.8, 1.82, 0.44), new THREE.Vector3(0, 1.82, 0.44), routeTravel * 2)
    else setAlong(routePacket, new THREE.Vector3(0, 1.82, 0.44), new THREE.Vector3(2.8, 1.82, 0.44), (routeTravel - 0.5) * 2)
    drive.rotation.y = elapsed * 0.18 * motion
    restored.rotation.y = -elapsed * 0.18 * motion
    chunkBlocks.forEach((block, index) => { block.position.z = Math.sin(elapsed * 0.8 + index) * 0.08 * motion })
    setAlong(backupPacket, new THREE.Vector3(-1.75, -1.35, 0.45), new THREE.Vector3(2.65, -1.35, 0.45), reducedMotion ? 0.78 : (elapsed * 0.16 + pulse * 0.76) % 1)

    portalScreens[0].scale.setScalar(1 + Math.sin(elapsed * 0.75) * 0.012 * motion)
    isoScan.position.y = 1.25 + Math.sin(elapsed * 1.2) * 0.7 * motion
  }

  return { groups, cameraFrames, update }
}

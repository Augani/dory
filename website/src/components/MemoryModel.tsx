import { useEffect, useRef, useState } from 'react'
import * as THREE from 'three'
import { Reveal } from './Reveal'
import { useReducedMotion } from '../hooks/useReducedMotion'

const MAX = 6

function box(w: number, h: number, d: number, mat: THREE.Material) {
  return new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat)
}
function edges(w: number, h: number, d: number, mat: THREE.LineBasicMaterial) {
  return new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.BoxGeometry(w, h, d)), mat)
}

function ModelFallback() {
  return (
    <div className="model-fallback">
      <svg
        viewBox="0 0 860 300"
        role="img"
        aria-label="Diagram: five per-container VMs each with their own kernel, versus one Dory VM containing five containers"
      >
        <g fontFamily="var(--font)" fontSize="13">
          <text x={215} y={28} fill="#475569" textAnchor="middle" fontWeight="700">
            ONE VM PER CONTAINER
          </text>
          <text x={645} y={28} fill="#16A34A" textAnchor="middle" fontWeight="700">
            DORY: ONE SHARED VM
          </text>
        </g>
        <g>
          {[30, 110, 190, 270, 350].map((x) => (
            <g key={x}>
              <rect x={x} y={50} width={70} height={200} rx={10} fill="none" stroke="#64748B" />
              <rect x={x + 10} y={212} width={50} height={28} rx={5} fill="#64748B" opacity={0.4} />
              <rect x={x + 17} y={120} width={36} height={36} rx={6} fill="#3D7BF4" />
            </g>
          ))}
        </g>
        <g>
          <rect x={480} y={50} width={330} height={200} rx={14} fill="rgba(46,155,245,.05)" stroke="#2E9BF5" />
          <rect x={495} y={212} width={300} height={28} rx={5} fill="#2E9BF5" opacity={0.3} />
          {[505, 565, 625, 685, 745].map((x) => (
            <rect key={x} x={x} y={100} width={44} height={44} rx={7} fill="#3D7BF4" />
          ))}
          <text x={645} y={285} fill="#64748B" fontSize={12} textAnchor="middle" fontFamily="var(--font)">
            one kernel, one memory pool, shared page cache
          </text>
        </g>
        <text x={215} y={285} fill="#64748B" fontSize={12} textAnchor="middle" fontFamily="var(--font)">
          five kernels, five memory floors
        </text>
      </svg>
    </div>
  )
}

export function MemoryModel() {
  const reduced = useReducedMotion()
  const wrapRef = useRef<HTMLDivElement>(null)
  const hostRef = useRef<HTMLDivElement>(null)
  const [vmOther, setVmOther] = useState('0 VMs')
  const [vmDory, setVmDory] = useState('1 VM')
  const [ctOther, setCtOther] = useState('0 containers, 0 kernels')
  const [ctDory, setCtDory] = useState('0 containers, 1 kernel')
  const addRef = useRef<() => void>(() => {})
  const resetRef = useRef<() => void>(() => {})

  useEffect(() => {
    if (reduced) return
    const wrap = wrapRef.current
    const host = hostRef.current
    if (!wrap || !host) return

    const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true })
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5))
    host.appendChild(renderer.domElement)

    const scene = new THREE.Scene()
    const camera = new THREE.PerspectiveCamera(38, 2, 0.1, 300)
    camera.position.set(0, 13, 46)
    camera.lookAt(0, 1, 0)

    scene.add(new THREE.AmbientLight(0x8fb6ff, 1.2))
    const key = new THREE.DirectionalLight(0xcfe4ff, 1.6)
    key.position.set(6, 18, 12)
    scene.add(key)
    const rim = new THREE.DirectionalLight(0x2e9bf5, 0.6)
    rim.position.set(-10, 6, -8)
    scene.add(rim)

    const world = new THREE.Group()
    scene.add(world)

    const MAT = {
      container: new THREE.MeshLambertMaterial({ color: 0x3d7bf4 }),
      containerTop: new THREE.MeshLambertMaterial({ color: 0x6cb8ff }),
      kernelOther: new THREE.MeshLambertMaterial({ color: 0x94a3b8 }),
      kernelDory: new THREE.MeshLambertMaterial({ color: 0x2e9bf5, transparent: true, opacity: 0.85 }),
      edgeOther: new THREE.LineBasicMaterial({ color: 0x64748b, transparent: true, opacity: 0.7 }),
      edgeDory: new THREE.LineBasicMaterial({ color: 0x2e9bf5, transparent: true, opacity: 0.85 }),
    }

    function containerCube() {
      const g = new THREE.Group()
      const c = box(2.2, 2.2, 2.2, MAT.container)
      const lid = box(2.2, 0.34, 2.2, MAT.containerTop)
      lid.position.y = 1.28
      g.add(c)
      g.add(lid)
      return g
    }

    const left = new THREE.Group()
    left.position.x = -13.5
    world.add(left)
    const right = new THREE.Group()
    right.position.x = 13.5
    world.add(right)

    const dShellW = 17
    const dShellH = 9.5
    const dShellD = 11
    right.add(edges(dShellW, dShellH, dShellD, MAT.edgeDory))
    const dKernel = box(dShellW - 1.6, 1.1, dShellD - 1.6, MAT.kernelDory)
    dKernel.position.y = -dShellH / 2 + 1.0
    right.add(dKernel)

    const spawned: { group: THREE.Object3D; born: number }[] = []
    let count = 0

    function leftSlot(i: number) {
      const col = i % 3
      const row = Math.floor(i / 3)
      return new THREE.Vector3((col - 1) * 6.4, 0, (row - 0.5) * 6.6)
    }
    function rightSlot(i: number) {
      const col = i % 3
      const row = Math.floor(i / 3)
      return new THREE.Vector3((col - 1) * 4.6, -dShellH / 2 + 2.9, (row - 0.5) * 4.4)
    }

    function updateHUD() {
      setVmOther(`${count} VM${count === 1 ? '' : 's'}`)
      setVmDory('1 VM')
      setCtOther(`${count} container${count === 1 ? '' : 's'}, ${count} kernel${count === 1 ? '' : 's'}`)
      setCtDory(`${count} container${count === 1 ? '' : 's'}, 1 kernel`)
    }

    function addContainer() {
      if (count >= MAX) return
      const i = count
      count++
      const vm = new THREE.Group()
      vm.position.copy(leftSlot(i))
      vm.add(edges(5.4, 7.2, 5.4, MAT.edgeOther))
      const k = box(4.4, 1.0, 4.4, MAT.kernelOther)
      k.position.y = -2.6
      vm.add(k)
      const cubeL = containerCube()
      cubeL.position.y = 0.4
      vm.add(cubeL)
      vm.scale.setScalar(0.01)
      left.add(vm)
      spawned.push({ group: vm, born: performance.now() })

      const cubeR = containerCube()
      cubeR.position.copy(rightSlot(i))
      cubeR.scale.setScalar(0.01)
      right.add(cubeR)
      spawned.push({ group: cubeR, born: performance.now() })
      updateHUD()
    }

    function reset() {
      for (const s of spawned) s.group.parent?.remove(s.group)
      spawned.length = 0
      count = 0
      updateHUD()
    }

    addRef.current = () => {
      userDrove = true
      addContainer()
    }
    resetRef.current = () => {
      userDrove = true
      reset()
    }

    let userDrove = false
    let targetRX = -0.12
    let targetRY = 0
    function onPointerMove(ev: PointerEvent) {
      const r = wrap!.getBoundingClientRect()
      const nx = (ev.clientX - r.left) / r.width - 0.5
      const ny = (ev.clientY - r.top) / r.height - 0.5
      targetRY = nx * 0.35
      targetRX = -0.12 - ny * 0.18
    }
    wrap.addEventListener('pointermove', onPointerMove, { passive: true })

    function resize() {
      const w = wrap!.clientWidth
      const h = host!.clientHeight || 520
      if (w < 10 || h < 10) return
      renderer.setSize(w, h, false)
      camera.aspect = w / h
      camera.updateProjectionMatrix()
    }
    const ro = new ResizeObserver(resize)
    ro.observe(wrap)
    resize()

    let lastAuto = 0
    updateHUD()

    // Fully stop the render loop off-screen (not just skip the draw call) so an
    // idle scroll position never contends with other work on the page, such as
    // a compositor-driven CSS transition elsewhere.
    function tick(now: number) {
      if (!userDrove && now - lastAuto > 2100) {
        lastAuto = now
        if (count >= MAX) reset()
        else addContainer()
      }
      for (const s of spawned) {
        const a = Math.min(1, (now - s.born) / 480)
        const e = 1 - Math.pow(1 - a, 3)
        s.group.scale.setScalar(Math.max(0.01, e))
      }
      world.rotation.y += (targetRY - world.rotation.y) * 0.05
      world.rotation.x += (targetRX - world.rotation.x) * 0.05
      renderer.render(scene, camera)
    }

    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          renderer.setAnimationLoop(e.isIntersecting ? tick : null)
        }
      },
      { threshold: 0.2 },
    )
    io.observe(wrap)

    return () => {
      renderer.setAnimationLoop(null)
      ro.disconnect()
      io.disconnect()
      wrap.removeEventListener('pointermove', onPointerMove)
      host.removeChild(renderer.domElement)
      renderer.dispose()
      Object.values(MAT).forEach((m) => m.dispose())
    }
  }, [reduced])

  return (
    <section id="model" style={{ paddingTop: 36 }}>
      <div className="wrap">
        <Reveal as="span" className="kicker">
          How Dory avoids per-container VMs
        </Reveal>
        <Reveal as="h2">Every VM you don't boot is RAM you keep.</Reveal>
        <Reveal as="p" className="lead">
          Per-container-VM engines boot a micro-VM (kernel, init, memory ballast){' '}
          <em>per container</em>. Dory's own doryd-managed engine boots <b>one</b> persistent VM
          instead, runs <code className="inline-code">dockerd</code> inside it, and every container
          shares that single kernel and memory pool. Watch what happens as containers stack up:
        </Reveal>
        <Reveal className="model-wrap" as="div">
          <div ref={wrapRef} style={{ position: 'relative' }}>
            {reduced ? (
              <ModelFallback />
            ) : (
              <>
                <div className="model-canvas-host" ref={hostRef} />
                <div className="hud">
                  <div className="hud-top">
                    <div className="hud-side other">
                      <div className="t">One VM per container</div>
                      <div className="mb">{vmOther}</div>
                      <div className="per">{ctOther}</div>
                    </div>
                    <div className="hud-side dory">
                      <div className="t">Dory: one shared VM</div>
                      <div className="mb">{vmDory}</div>
                      <div className="per">{ctDory}</div>
                    </div>
                  </div>
                  <div className="hud-bottom">
                    <button className="btn btn-primary" onClick={() => addRef.current()}>
                      + Run another container
                    </button>
                    <button className="btn btn-ghost" onClick={() => resetRef.current()}>
                      Reset
                    </button>
                  </div>
                </div>
              </>
            )}
          </div>
        </Reveal>
        <Reveal as="p" className="model-note">
          Illustrative architecture, not a memory estimate. Fresh total-footprint comparisons ship
          only with repeatable process attribution and raw samples; see{' '}
          <a
            href="https://github.com/Augani/dory/blob/main/BENCHMARKS.md"
            className="link"
          >
            BENCHMARKS.md
          </a>
          .
        </Reveal>
      </div>
    </section>
  )
}

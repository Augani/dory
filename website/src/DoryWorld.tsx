import { useEffect, useRef, type MutableRefObject } from 'react'
import * as THREE from 'three'
import { createDorySceneRig } from './DorySceneRig'

function materialList(object: THREE.Object3D) {
  const candidate = object as THREE.Object3D & { material?: THREE.Material | THREE.Material[] }
  if (!candidate.material) return []
  return Array.isArray(candidate.material) ? candidate.material : [candidate.material]
}

function prepareFadeGroup(group: THREE.Group) {
  group.traverse((object) => {
    materialList(object).forEach((material) => {
      material.transparent = true
      material.userData.baseOpacity = material.opacity
    })
  })
}

function setGroupOpacity(group: THREE.Group, alpha: number) {
  group.visible = alpha > 0.015
  if (!group.visible) return
  group.traverse((object) => {
    materialList(object).forEach((material) => {
      const base = typeof material.userData.baseOpacity === 'number' ? material.userData.baseOpacity : 1
      material.opacity = base * alpha
    })
  })
}

function disposeWorld(scene: THREE.Scene) {
  scene.traverse((object) => {
    const disposable = object as THREE.Object3D & { geometry?: THREE.BufferGeometry; material?: THREE.Material | THREE.Material[] }
    disposable.geometry?.dispose()
    const materials = disposable.material ? (Array.isArray(disposable.material) ? disposable.material : [disposable.material]) : []
    materials.forEach((material) => {
      Object.values(material).forEach((value) => {
        if (value instanceof THREE.Texture) value.dispose()
      })
      material.dispose()
    })
  })
}

function seededRandom(seed: number) {
  let value = seed >>> 0
  return () => {
    value = (value * 1664525 + 1013904223) >>> 0
    return value / 4294967296
  }
}

export default function DoryWorld({ progressRef, pulseRef, chapterCount, onContextState }: {
  progressRef: MutableRefObject<number>
  pulseRef: MutableRefObject<number>
  chapterCount: number
  onContextState: (lost: boolean) => void
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const coarsePointer = window.matchMedia('(pointer: coarse)').matches
    const compact = window.matchMedia('(max-width: 760px)').matches
    const scene = new THREE.Scene()
    scene.background = new THREE.Color(0x030507)
    scene.fog = new THREE.FogExp2(0x030507, 0.026)

    let renderer: THREE.WebGLRenderer
    try {
      renderer = new THREE.WebGLRenderer({ canvas, antialias: !compact, powerPreference: 'high-performance' })
    } catch {
      onContextState(true)
      return
    }

    renderer.outputColorSpace = THREE.SRGBColorSpace
    renderer.toneMapping = THREE.ACESFilmicToneMapping
    renderer.toneMappingExposure = 1.24
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, compact ? 1.25 : 1.75))

    const camera = new THREE.PerspectiveCamera(compact ? 46 : 42, 1, 0.1, 90)
    const lookTarget = new THREE.Vector3()
    const random = seededRandom(1847)
    const rig = createDorySceneRig({ compact, random, chapterCount })
    rig.groups.forEach((group) => {
      prepareFadeGroup(group)
      scene.add(group)
    })
    camera.position.set(rig.cameraFrames[0].position[0], rig.cameraFrames[0].position[1], rig.cameraFrames[0].position[2])
    lookTarget.set(rig.cameraFrames[0].target[0], rig.cameraFrames[0].target[1], rig.cameraFrames[0].target[2])

    scene.add(new THREE.HemisphereLight(0xc7e4f7, 0x071018, 1.7))
    const keyLight = new THREE.DirectionalLight(0xffffff, 3.5)
    keyLight.position.set(4, 7, 9)
    scene.add(keyLight)
    const sideLight = new THREE.DirectionalLight(0x63bfff, 2.1)
    sideLight.position.set(-6, 2, 4)
    scene.add(sideLight)
    const pulseLight = new THREE.PointLight(0x70c7ff, 0, 18, 1.5)
    scene.add(pulseLight)

    const starCount = compact ? 240 : 480
    const starPositions = new Float32Array(starCount * 3)
    for (let index = 0; index < starCount; index += 1) {
      const radius = 15 + random() * 25
      const theta = random() * Math.PI * 2
      starPositions[index * 3] = Math.cos(theta) * radius
      starPositions[index * 3 + 1] = (random() - 0.5) * 25
      starPositions[index * 3 + 2] = Math.sin(theta) * radius
    }
    const starGeometry = new THREE.BufferGeometry()
    starGeometry.setAttribute('position', new THREE.BufferAttribute(starPositions, 3))
    const stars = new THREE.Points(starGeometry, new THREE.PointsMaterial({ color: 0x6f8ba1, size: compact ? 0.02 : 0.027, transparent: true, opacity: 0.32, depthWrite: false }))
    scene.add(stars)

    const grid = new THREE.GridHelper(44, 44, 0x27465e, 0x13212d)
    grid.position.y = compact ? -2.35 : -3.65
    const gridMaterials = Array.isArray(grid.material) ? grid.material : [grid.material]
    gridMaterials.forEach((material) => { material.transparent = true; material.opacity = 0.18 })
    scene.add(grid)

    let pointerX = 0
    let pointerY = 0
    let pulseEnergy = 0
    let previousPulse = pulseRef.current
    let animationFrame = 0
    const desiredPosition = new THREE.Vector3()
    const desiredTarget = new THREE.Vector3()

    const resize = () => {
      const width = canvas.clientWidth
      const height = canvas.clientHeight
      if (!width || !height) return
      renderer.setSize(width, height, false)
      camera.aspect = width / height
      camera.updateProjectionMatrix()
    }
    const resizeObserver = new ResizeObserver(resize)
    resizeObserver.observe(canvas)
    resize()

    const onPointerMove = (event: PointerEvent) => {
      if (coarsePointer || reducedMotion) return
      pointerX = (event.clientX / window.innerWidth - 0.5) * 2
      pointerY = (event.clientY / window.innerHeight - 0.5) * 2
    }
    const onContextLost = (event: Event) => {
      event.preventDefault()
      onContextState(true)
    }
    const onContextRestored = () => onContextState(false)
    window.addEventListener('pointermove', onPointerMove, { passive: true })
    canvas.addEventListener('webglcontextlost', onContextLost)
    canvas.addEventListener('webglcontextrestored', onContextRestored)

    const render = (time: number) => {
      animationFrame = requestAnimationFrame(render)
      if (document.hidden) return

      const progress = THREE.MathUtils.clamp(progressRef.current, 0, 1)
      const phase = progress * (chapterCount - 1)
      const lower = Math.floor(phase)
      const upper = Math.min(chapterCount - 1, lower + 1)
      const mix = phase - lower
      const positionA = rig.cameraFrames[lower].position
      const positionB = rig.cameraFrames[upper].position
      const targetA = rig.cameraFrames[lower].target
      const targetB = rig.cameraFrames[upper].target
      desiredPosition.set(
        THREE.MathUtils.lerp(positionA[0], positionB[0], mix) + pointerX * 0.22,
        THREE.MathUtils.lerp(positionA[1], positionB[1], mix) - pointerY * 0.14,
        THREE.MathUtils.lerp(positionA[2], positionB[2], mix),
      )
      desiredTarget.set(
        THREE.MathUtils.lerp(targetA[0], targetB[0], mix),
        THREE.MathUtils.lerp(targetA[1], targetB[1], mix),
        THREE.MathUtils.lerp(targetA[2], targetB[2], mix),
      )
      camera.position.lerp(desiredPosition, reducedMotion ? 1 : 0.09)
      lookTarget.lerp(desiredTarget, reducedMotion ? 1 : 0.1)
      camera.lookAt(lookTarget)

      rig.groups.forEach((group, index) => {
        const distance = Math.abs(index - phase)
        const alpha = 1 - THREE.MathUtils.smoothstep(distance, 0.32, 0.92)
        setGroupOpacity(group, THREE.MathUtils.clamp(alpha, 0, 1))
      })

      if (pulseRef.current !== previousPulse) {
        previousPulse = pulseRef.current
        pulseEnergy = 1
      }
      pulseEnergy *= reducedMotion ? 0.58 : 0.945
      const currentGroup = rig.groups[Math.min(chapterCount - 1, Math.round(phase))]
      pulseLight.position.set(currentGroup.position.x, currentGroup.position.y + 0.8, 3)
      pulseLight.intensity = pulseEnergy * 13
      pulseLight.distance = 14 + pulseEnergy * 8

      rig.update({ time, phase, pulse: pulseEnergy, reducedMotion })
      if (!reducedMotion) stars.rotation.y = time * 0.000004
      renderer.render(scene, camera)
    }
    animationFrame = requestAnimationFrame(render)

    return () => {
      cancelAnimationFrame(animationFrame)
      resizeObserver.disconnect()
      window.removeEventListener('pointermove', onPointerMove)
      canvas.removeEventListener('webglcontextlost', onContextLost)
      canvas.removeEventListener('webglcontextrestored', onContextRestored)
      disposeWorld(scene)
      renderer.dispose()
      window.setTimeout(() => {
        if (!canvas.isConnected) renderer.forceContextLoss()
      }, 0)
    }
  }, [chapterCount, onContextState, progressRef, pulseRef])

  return <canvas ref={canvasRef} className="dory-world" aria-hidden="true" />
}

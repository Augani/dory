import { useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import {
  ArrowDownIcon,
  ArrowLeftIcon,
  ArrowRightIcon,
  BoltIcon,
  SpeakerWaveIcon,
} from '@heroicons/react/24/outline'
import DoryWorld from './DoryWorld'

type Chapter = {
  eyebrow: string
  title: string
  body: string
  facts: [string, string][]
  action: string
}

const chapters: Chapter[] = [
  {
    eyebrow: 'The whole system',
    title: 'A development computer—not another utility.',
    body: 'Dory treats containers, clusters, Linux computers, agent environments, networking, storage, and recovery as one machine with one lifecycle. Scroll to travel through the system it keeps beneath your work.',
    facts: [['One control plane', 'App → daemon → guest'], ['Local by design', 'No account required'], ['Current host', 'Apple Silicon']],
    action: 'Start the system',
  },
  {
    eyebrow: 'One engine, many worlds',
    title: 'Containers, Kubernetes, and Linux share a foundation.',
    body: 'A native engine speaks the Docker workflows developers already know. Beside it, k3s clusters and persistent ARM64 machines get deliberate disks, networks, devices, and readiness—not a pile of unrelated background processes.',
    facts: [['Containers', 'Docker CLI + Compose'], ['Clusters', 'Local k3s'], ['Computers', 'Persistent ARM64 guests']],
    action: 'Trace the engine',
  },
  {
    eyebrow: 'Machines for agents',
    title: 'Every agent gets a real boundary.',
    body: 'Dory detects Node, Python, Go, Rust, Java, and Ruby projects, prepares the matching toolchains, and captures a clean reset baseline. Each sandbox is non-root, policy-bound, disposable, and isolated from host files unless you grant access.',
    facts: [['Runtime', 'Detected from the project'], ['Network', 'None · granted outbound · full'], ['Reset', 'Sparse baseline captured']],
    action: 'Provision an agent',
  },
  {
    eyebrow: 'Memory that gives back',
    title: 'Fast while working. Light when waiting.',
    body: 'Dory watches host pressure and guest PSI, separates real working sets from reclaimable cache, and adjusts memory in bounded steps. Your active work keeps headroom; idle pages return to macOS.',
    facts: [['Host', 'Pressure sampled'], ['Guest', 'PSI observed'], ['Policy', 'Working set protected']],
    action: 'Return idle memory',
  },
  {
    eyebrow: 'Idle is a real state',
    title: 'The engine can disappear without losing the work.',
    body: 'Auto-Idle can stop the engine after 5, 15, 30, or 60 minutes. Published ports, Kubernetes, and pinned projects are explicit wake blockers. The next request wakes Dory through ordered readiness gates instead of a blind restart.',
    facts: [['Sleep policy', '5 · 15 · 30 · 60 min'], ['Wake blockers', 'Ports · k3s · pins'], ['Readiness', 'Nine verified stages']],
    action: 'Wake the engine',
  },
  {
    eyebrow: 'Routes and data that can return',
    title: 'Everything Dory changes has an owner and an exit.',
    body: 'Published ports stay localhost-first. Optional DNS, trusted local TLS, low-port routing, LAN, and VPN visibility are explicit changes with removal boundaries. Durable data lives on a managed drive; backup and restore publish only after independent verification.',
    facts: [['Network', 'Localhost by default'], ['Storage', 'One managed Dory drive'], ['Recovery', 'Verify before publish']],
    action: 'Verify the return',
  },
  {
    eyebrow: 'Two gated horizons',
    title: 'Linux is here. Other desktops have to earn their light.',
    body: 'Managed Linux desktops are supported today. Custom ARM64 ISO installation remains preview and qualification-bound. Windows ARM and macOS guests are separate, deferred engineering programs that can share Dory’s lifecycle and recovery contracts without pretending one backend fits every operating system.',
    facts: [['Supported', 'Managed Linux ARM64'], ['Preview', 'Custom ARM64 ISO'], ['Deferred', 'Windows ARM + macOS']],
    action: 'See the horizon',
  },
]

export default function DoryExperience() {
  const [activeChapter, setActiveChapter] = useState(0)
  const [progress, setProgress] = useState(0)
  const [contextLost, setContextLost] = useState(false)
  const [soundOn, setSoundOn] = useState(false)
  const [announcement, setAnnouncement] = useState('')
  const progressRef = useRef(0)
  const pulseRef = useRef(0)
  const audioRef = useRef<AudioContext | null>(null)
  const sectionRefs = useRef<(HTMLElement | null)[]>([])

  const chapterNumber = useMemo(() => String(activeChapter + 1).padStart(2, '0'), [activeChapter])

  useEffect(() => {
    let scheduled = 0
    const updateProgress = () => {
      scheduled = 0
      const maximum = Math.max(1, document.documentElement.scrollHeight - window.innerHeight)
      const next = Math.max(0, Math.min(1, window.scrollY / maximum))
      progressRef.current = next
      setProgress(next)
      setActiveChapter(Math.min(chapters.length - 1, Math.round(next * (chapters.length - 1))))
    }
    const onScroll = () => {
      if (!scheduled) scheduled = requestAnimationFrame(updateProgress)
    }
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    updateProgress()
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      if (scheduled) cancelAnimationFrame(scheduled)
    }
  }, [])

  useEffect(() => {
    if (!soundOn) {
      if (audioRef.current) {
        void audioRef.current.close()
        audioRef.current = null
      }
      return
    }
    if (typeof AudioContext === 'undefined') {
      setSoundOn(false)
      setAnnouncement('Ambient audio is not available in this browser.')
      return
    }

    const context = new AudioContext()
    const master = context.createGain()
    const low = context.createOscillator()
    const high = context.createOscillator()
    const lowGain = context.createGain()
    const highGain = context.createGain()
    const filter = context.createBiquadFilter()
    const lfo = context.createOscillator()
    const lfoGain = context.createGain()
    master.gain.value = 0.12
    low.type = 'sine'
    low.frequency.value = 48
    lowGain.gain.value = 0.13
    high.type = 'triangle'
    high.frequency.value = 91
    highGain.gain.value = 0.025
    filter.type = 'lowpass'
    filter.frequency.value = 440
    filter.Q.value = 0.8
    lfo.type = 'sine'
    lfo.frequency.value = 0.07
    lfoGain.gain.value = 0.035
    low.connect(lowGain).connect(filter)
    high.connect(highGain).connect(filter)
    lfo.connect(lfoGain).connect(master.gain)
    filter.connect(master).connect(context.destination)
    low.start()
    high.start()
    lfo.start()
    void context.resume()
    audioRef.current = context
    return () => {
      if (context.state !== 'closed') void context.close()
      if (audioRef.current === context) audioRef.current = null
    }
  }, [soundOn])

  const goToChapter = (index: number) => {
    const bounded = Math.max(0, Math.min(chapters.length - 1, index))
    sectionRefs.current[bounded]?.scrollIntoView({
      behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth',
      block: 'center',
    })
  }

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const tag = (document.activeElement as HTMLElement | null)?.tagName
      if (tag === 'A' || tag === 'BUTTON' || tag === 'INPUT' || tag === 'TEXTAREA') return
      if (event.key === 'ArrowDown' || event.key === 'PageDown') {
        event.preventDefault()
        goToChapter(activeChapter + 1)
      }
      if (event.key === 'ArrowUp' || event.key === 'PageUp') {
        event.preventDefault()
        goToChapter(activeChapter - 1)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [activeChapter])

  const activateChapter = () => {
    pulseRef.current += 1
    setAnnouncement(`${chapters[activeChapter].action}: chapter visualization replayed`)
    window.setTimeout(() => setAnnouncement(''), 1800)
  }

  const panelSide = activeChapter % 2 === 0 ? 'panel-left' : 'panel-right'

  return (
    <div className={`experience-shell ${panelSide}`}>
      <DoryWorld progressRef={progressRef} pulseRef={pulseRef} chapterCount={chapters.length} onContextState={setContextLost} />
      <div className="world-vignette" aria-hidden="true" />

      <header className="experience-header">
        <a className="experience-back" href="../"><ArrowLeftIcon /> <span>Dory</span></a>
        <div className="experience-title"><span>Inside the system</span><i />Interactive engineering tour</div>
        <button type="button" className="sound-control" aria-pressed={soundOn} onClick={() => setSoundOn((current) => !current)}>
          <SpeakerWaveIcon /> {soundOn ? 'Atmosphere on' : 'Atmosphere off'}
        </button>
      </header>

      <nav className="chapter-rail" aria-label="Experience chapters">
        <span className="rail-progress" style={{ '--tour-progress': progress } as CSSProperties} />
        {chapters.map((chapter, index) => (
          <button key={chapter.eyebrow} type="button" className={index === activeChapter ? 'is-active' : ''} aria-label={`Go to chapter ${index + 1}: ${chapter.eyebrow}`} onClick={() => goToChapter(index)}>
            <i /><span>{String(index + 1).padStart(2, '0')}</span>
          </button>
        ))}
      </nav>

      <main className="experience-story">
        {chapters.map((chapter, index) => (
          <section
            className={`experience-chapter chapter-${index + 1}`}
            key={chapter.eyebrow}
            ref={(element) => { sectionRefs.current[index] = element }}
            aria-labelledby={`chapter-title-${index}`}
          >
            <div className="chapter-panel">
              <p className="chapter-kicker"><span>{String(index + 1).padStart(2, '0')}</span>{chapter.eyebrow}</p>
              {index === 0 ? <h1 id={`chapter-title-${index}`}>{chapter.title}</h1> : <h2 id={`chapter-title-${index}`}>{chapter.title}</h2>}
              <p className="chapter-body">{chapter.body}</p>
              <dl className="chapter-facts">
                {chapter.facts.map(([term, description]) => <div key={term}><dt>{term}</dt><dd>{description}</dd></div>)}
              </dl>
              <div className="chapter-actions">
                <button type="button" onClick={activateChapter}><BoltIcon />{chapter.action}</button>
                {index < chapters.length - 1
                  ? <button type="button" className="next-chapter" onClick={() => goToChapter(index + 1)}>Continue <ArrowDownIcon /></button>
                  : <a className="next-chapter" href="../#download">Build with Dory <ArrowRightIcon /></a>}
              </div>
            </div>
          </section>
        ))}
      </main>

      <aside className="experience-hud" aria-hidden="true">
        <span>CH {chapterNumber}</span>
        <strong>{chapters[activeChapter].eyebrow}</strong>
        <i><b style={{ width: `${progress * 100}%` }} /></i>
      </aside>

      {contextLost && (
        <div className="webgl-fallback" role="status">
          <strong>The visual engine paused.</strong>
          <p>The full Dory story remains available. Reload this page to restore the interactive world.</p>
          <button type="button" onClick={() => window.location.reload()}>Reload experience</button>
        </div>
      )}
      <p className="sr-only" aria-live="polite">{announcement}</p>
    </div>
  )
}

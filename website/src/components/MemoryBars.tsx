import { useEffect, useRef, useState } from 'react'

export function MemoryBars() {
  const cardRef = useRef<HTMLDivElement>(null)
  const [filled, setFilled] = useState(false)

  useEffect(() => {
    const el = cardRef.current
    if (!el) return
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setFilled(true)
            io.disconnect()
          }
        }
      },
      { threshold: 0.4 },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])

  return (
    <section id="memory" style={{ paddingTop: 40 }}>
      <div className="wrap">
        <span className="kicker">A memory architecture you can inspect</span>
        <h2>One VM, with host-aware reclaim.</h2>
        <div className="mem-card" ref={cardRef}>
          <div className="mem-row">
            <div className="label">
              <b>Dory: one shared VM</b>
              <span>All containers share one persistent Linux engine</span>
            </div>
            <div className="track">
              <div className="fill dory" style={{ width: filled ? '100%' : 0 }} />
            </div>
          </div>
          <div className="mem-row">
            <div className="label">
              <b>Memory returns to macOS</b>
              <span>Free-page reporting plus pressure-triggered reclaim</span>
            </div>
            <div className="track">
              <div className="fill other" style={{ width: filled ? '72%' : 0 }} />
            </div>
          </div>
          <div className="mem-big">
            <span className="x">Open</span>
            <span>benchmark rules, raw samples, and no unsupported multiplier</span>
          </div>
          <div className="mem-note">
            Fresh total-footprint comparisons will be published only with repeatable process-tree
            attribution and raw samples (
            <a
              href="https://github.com/Augani/dory/blob/main/BENCHMARKS.md"
              className="link"
            >
              benchmark rules
            </a>
            ). Intel tables will likewise wait for physical-hardware readiness and benchmark gates.
          </div>
        </div>
      </div>
    </section>
  )
}

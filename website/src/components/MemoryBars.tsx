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
        <span className="kicker">Measured, not promised</span>
        <h2>Your RAM belongs to you.</h2>
        <div className="mem-card" ref={cardRef}>
          <div className="mem-row">
            <div className="label">
              <b>Dory: one shared VM</b>
              <span>~122 MB · 2 idle containers</span>
            </div>
            <div className="track">
              <div className="fill dory" style={{ width: filled ? '21%' : 0 }} />
            </div>
          </div>
          <div className="mem-row">
            <div className="label">
              <b>One VM per container</b>
              <span>~574 MB · 2 idle containers</span>
            </div>
            <div className="track">
              <div className="fill other" style={{ width: filled ? '100%' : 0 }} />
            </div>
          </div>
          <div className="mem-big">
            <span className="x">~4.7x</span>
            <span>less idle memory, and the gap widens with every container you add</span>
          </div>
          <div className="mem-note">
            *Measured by Dory on Apple silicon (
            <a
              href="https://github.com/Augani/dory/blob/main/website/public/research/benchmark-methodology.md"
              className="link"
            >
              methodology
            </a>
            ). Intel memory and file-sharing tables will be published only after the physical Intel
            readiness and benchmark gates pass.
          </div>
        </div>
      </div>
    </section>
  )
}

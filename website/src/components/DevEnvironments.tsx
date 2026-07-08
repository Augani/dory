import { Reveal } from './Reveal'

const asset = (path: string) => `${import.meta.env.BASE_URL}${path}`

export function DevEnvironments() {
  return (
    <section id="devenv" className="alt" style={{ paddingTop: 30 }}>
      <div className="wrap">
        <Reveal as="span" className="kicker">
          Dev environments
        </Reveal>
        <Reveal as="h2">A ready-to-code machine in three moves.</Reveal>
        <Reveal as="p" className="lead">
          Not just containers: Dory builds whole development environments. Pick what you're building,
          and the machine arrives with the toolchain already on it.
        </Reveal>
        <Reveal className="flow">
          <div className="step">
            <span className="n">1</span>
            <h3>Pick your stack</h3>
            <p>Choose a use-case and Dory picks the recipe, or compose your own from runtimes, tools, and packages.</p>
            <div className="chips">
              <span className="chip">Web / Node.js</span>
              <span className="chip">Python &amp; ML</span>
              <span className="chip">Go</span>
              <span className="chip">Rust</span>
              <span className="chip">Java / JVM</span>
              <span className="chip">DevOps &amp; CI</span>
              <span className="chip">Build your own</span>
            </div>
          </div>
          <div className="arrow" aria-hidden="true">
            →
          </div>
          <div className="step">
            <span className="n">2</span>
            <h3>It provisions itself</h3>
            <p>The machine boots and installs its own toolchain. You watch it happen, then get a terminal.</p>
            <div className="mini-term">
              <span className="p">$</span> creating ubuntu machine <span className="b">web</span>…{'\n'}
              <span className="g">✓</span> node 24 · npm · pnpm{'\n'}
              <span className="g">✓</span> git · build tools · ssh{'\n'}
              <span className="b">→ web.dory.local</span> <span className="g">ready</span>
              {'\n'}
              <span className="p">$</span> dory ssh web
            </div>
          </div>
          <div className="arrow" aria-hidden="true">
            →
          </div>
          <div className="step">
            <span className="n">3</span>
            <h3>Break it. Snapshot it. Reset it.</h3>
            <p>
              Snapshot before a risky upgrade and roll back in seconds. Your shell's env vars and
              registry logins can flow into the machine, consent-gated, from an allow-list you control.
            </p>
            <div className="snap">
              <b>◉ snapshot</b> web · before-node-25 · restore anytime
            </div>
          </div>
        </Reveal>
        <Reveal className="devshot" as="div">
          <div className="shot">
            <img
              src={asset('shots/newmachine.png')}
              width={1400}
              height={911}
              alt="Dory's new machine sheet: use-case cards for Web/Node.js, Python and ML, Go, Rust, Java, DevOps, a clean Linux, or a custom composition"
              loading="lazy"
            />
          </div>
        </Reveal>
      </div>
    </section>
  )
}

import { Reveal } from './Reveal'

export function Footprint() {
  return (
    <section id="footprint" className="alt">
      <div className="wrap">
        <Reveal as="span" className="kicker">
          What you can hold us to
        </Reveal>
        <Reveal as="h2">Small. Silent. Yours.</Reveal>
        <Reveal as="p" className="lead">
          Other tools will change their features and their pricing; that's their business. Here's
          what Dory is built to be, permanently:
        </Reveal>
        <div className="promise">
          <Reveal className="pcard">
            <div className="big">~6 MB</div>
            <div className="t">Lite app</div>
            <p>
              Native Swift, no Electron, no bundled browser, no Node sidecar. The full release adds
              the engine, Docker, Compose, and kubectl for clean Macs.
            </p>
          </Reveal>
          <Reveal className="pcard">
            <div className="big">Measured</div>
            <div className="t">Idle CPU</div>
            <p>
              No indexers or phone-home loop. Every release candidate must pass an attributed
              eight-hour CPU, memory, and descriptor plateau gate.
            </p>
          </Reveal>
          <Reveal className="pcard">
            <div className="big">1 VM</div>
            <div className="t">For everything</div>
            <p>
              One kernel and one memory pool, with free-page reporting. Host-pressure reclaim is
              available in the opt-in experimental Senpai mode.
            </p>
          </Reveal>
          <Reveal className="pcard">
            <div className="big">GPL-3.0</div>
            <div className="t">Forever</div>
            <p>No accounts, no telemetry, no paid tier, no rug to pull. The source is the guarantee.</p>
          </Reveal>
        </div>
        <Reveal as="p" className="compare-note">
          Don't take our word for anything. The{' '}
          <a
            href="https://github.com/Augani/dory/blob/main/BENCHMARKS.md"
            className="link"
          >
            benchmark methodology
          </a>
          , a{' '}
          <a href="https://github.com/Augani/dory/blob/main/website/public/comparison.md" className="link">
            sourced comparison
          </a>
          , and the per-feature{' '}
          <a href="https://github.com/Augani/dory/blob/main/COMPATIBILITY.md" className="link">
            status matrix
          </a>{' '}
          are all public. Judge for yourself.
        </Reveal>
      </div>
    </section>
  )
}

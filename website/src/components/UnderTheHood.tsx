import { Reveal } from './Reveal'

export function UnderTheHood() {
  return (
    <section id="hood" className="alt" style={{ paddingTop: 30 }}>
      <div className="wrap">
        <Reveal as="span" className="kicker">
          Under the hood
        </Reveal>
        <Reveal as="h2">Built like a systems tool, not a wrapper.</Reveal>
        <Reveal as="p" className="lead">
          Dory's transport, HTTP server, YAML parser, and Docker API layer are hand-rolled Swift. No
          Electron, no Node sidecars, no frameworks between your CLI and the engine. doryd is the
          launchd-owned control plane, and each local VM is supervised through Dory's own
          Hypervisor.framework helpers.
        </Reveal>
        <div className="hood">
          <Reveal className="hood-card">
            <h3>A real Docker socket</h3>
            <p>
              Dory serves the Docker Engine API on a unix socket with its own HTTP/1.1 implementation,
              including connection hijack for <code className="inline-code">exec</code> and{' '}
              <code className="inline-code">attach</code> streams, and registers a{' '}
              <code className="inline-code">dory</code> context so the CLI you already have just
              points at it.
            </p>
            <div className="term">
              <span className="p">$</span> docker context show{'\n'}
              <span className="g">dory</span>
              {'\n'}
              <span className="p">$</span> curl --unix-socket ~/.dory/dory.sock \{'\n'}
              {'    '}http://localhost/version{'\n'}
              <span className="b">{'{"Version":"29.5.3", ...}'}</span>
            </div>
          </Reveal>
          <Reveal className="hood-card">
            <h3>Domains &amp; TLS, locally issued</h3>
            <p>
              Every container gets <code className="inline-code">name.dory.local</code> via a scoped
              resolver entry. Dory runs its own certificate authority, mints per-host certs on the
              fly, terminates TLS in-app, and proxies to the container. Consent-gated: nothing touches
              your system silently.
            </p>
            <div className="term">
              <span className="p">$</span> curl -I https://web-api.dory.local{'\n'}
              <span className="g">HTTP/2 200</span>
              {'\n'}
              <span className="b">issuer: Dory Local CA</span>
              {'\n'}
              <span className="p">$</span> docker run -p 3000 --name api node:24{'\n'}
              <span className="b">→ https://api.dory.local</span>
            </div>
          </Reveal>
          <Reveal className="hood-card">
            <h3>One VM, one engine</h3>
            <p>
              Dory boots one persistent Linux VM and runs <code className="inline-code">dockerd</code>
              inside it. virtiofs shares your home directory at the same path, so bind mounts resolve
              with zero setup. Apple Silicon uses bundled FEX for amd64 images; Intel support is a later release track.
            </p>
            <div className="term">
              <span className="p">$</span> docker run -v ~/proj:/app alpine ls /app{'\n'}
              <span className="b">(your files, no sharing dialogs)</span>
              {'\n'}
              <span className="p">$</span> docker run --platform linux/amd64 postgres{'\n'}
              <span className="g">✓ native on Intel, emulated on Apple silicon</span>
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  )
}

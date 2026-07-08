import { Reveal } from './Reveal'

interface FeatureRowProps {
  flip?: boolean
  imgSrc: string
  imgAlt: string
  tag: string
  title: string
  children: React.ReactNode
}

function FeatureRow({ flip, imgSrc, imgAlt, tag, title, children }: FeatureRowProps) {
  return (
    <Reveal className={`frow${flip ? ' flip' : ''}`}>
      <div className="shot">
        <img src={imgSrc} width={1400} height={911} alt={imgAlt} loading="lazy" />
      </div>
      <div>
        <span className="tag">{tag}</span>
        <h3>{title}</h3>
        <ul>{children}</ul>
      </div>
    </Reveal>
  )
}

const asset = (path: string) => `${import.meta.env.BASE_URL}${path}`

export function Features() {
  return (
    <section id="features">
      <div className="wrap">
        <Reveal as="span" className="kicker">
          What you actually get
        </Reveal>
        <Reveal as="h2">The whole workflow, not a demo.</Reveal>

        <FeatureRow
          imgSrc={asset('shots/stats.png')}
          imgAlt="Dory containers view: live CPU and memory, compose grouping, and a detail pane with stats, domain, ports and restart policy"
          tag="Containers"
          title="Everything about a container, one pane away."
        >
          <li>Live CPU &amp; memory with per-container history, sampled from the real stats API.</li>
          <li>
            Logs stream in color; an embedded terminal drops you into <code>exec</code> without leaving
            the app.
          </li>
          <li>Compose projects group automatically, so you stop a whole stack in one click.</li>
          <li>
            Every container shows its <code>*.dory.local</code> domain, IP, ports, and restart policy.
          </li>
        </FeatureRow>

        <FeatureRow
          flip
          imgSrc={asset('shots/kubernetes.png')}
          imgAlt="Dory Kubernetes view: cluster health, node and pod counts, and a pod table across namespaces"
          tag="Kubernetes"
          title="A cluster you turn on, not one you assemble."
        >
          <li>One-click k3s inside the same shared VM: no second VM tax, no kind/minikube yak-shave.</li>
          <li>Pick your Kubernetes version; browse pods, deployments, services, config, secrets, ingress.</li>
          <li>
            Exec into pods, scale and restart deployments, <code>kubectl apply</code> from the app.
          </li>
          <li>
            Your existing <code>kubectl</code> works; Dory just wires the kubeconfig.
          </li>
        </FeatureRow>

        <FeatureRow
          imgSrc={asset('shots/machines.png')}
          imgAlt="Dory Linux machines view: Ubuntu, Debian, Fedora, and Arch machines with live CPU and memory, terminal buttons, and dory.local addresses"
          tag="Linux machines"
          title="Real Linux, one click away."
        >
          <li>Full Ubuntu, Debian, Fedora, Alpine, or Arch VMs, with systemd, SSH, terminal, and snapshots.</li>
          <li>Live CPU and memory per machine, right in the grid.</li>
          <li>
            Each machine gets a <code>name.dory.local</code> address, and the UI shows the copyable{' '}
            <code>dory ssh name</code> command for any terminal.
          </li>
          <li>Assign custom addresses, mounts, ports, CPU, memory, and recipes before creation.</li>
        </FeatureRow>

        <FeatureRow
          flip
          imgSrc={asset('shots/compose.png')}
          imgAlt="Dory compose view: a project with its services and one-click stack control"
          tag="Compose & migration"
          title="Your stack, your files, zero rewrites."
        >
          <li>
            Dory parses <code>compose.yaml</code> natively: <code>.env</code> + variable
            interpolation, <code>depends_on</code> ordering, and <code>service_healthy</code> waits via
            real health probes.
          </li>
          <li>Migration imports images and containers from Docker Desktop or OrbStack after a confidence report.</li>
          <li>Managed settings export local policy for engine route, domains, file sharing, Auto-Idle, and telemetry none.</li>
          <li>First launch is guided end-to-end, including a one-click engine toolchain install.</li>
          <li>
            Honest scorecard: every feature's status is tracked publicly in{' '}
            <a
              href="https://github.com/Augani/dory/blob/main/COMPATIBILITY.md"
              className="link"
            >
              COMPATIBILITY.md
            </a>
            .
          </li>
        </FeatureRow>
      </div>
    </section>
  )
}

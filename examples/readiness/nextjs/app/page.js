const checks = [
  ["Docker build", "Next.js image built inside Dory"],
  ["Port forwarding", "Published from the container to localhost"],
  ["Domain proxy", "Reachable through dory.local routing"],
  ["Health API", "/api/health returns nextjs-ok"]
];

export default function Page() {
  return (
    <main className="shell">
      <section className="hero">
        <img className="mark" src="/dory-next.svg" alt="" />
        <div>
          <p className="system">Dory readiness example</p>
          <h1>Dory Next.js readiness</h1>
          <p className="lede">
            This page is running from a Dockerized Next.js app inside Dory's shared Linux VM.
          </p>
        </div>
      </section>

      <section className="panel" aria-label="Readiness checks">
        {checks.map(([title, detail]) => (
          <article key={title}>
            <strong>{title}</strong>
            <span>{detail}</span>
          </article>
        ))}
      </section>

      <footer>
        <span className="pulse" aria-hidden="true" />
        live through Dory
      </footer>
    </main>
  );
}

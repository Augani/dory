import SwiftUI

nonisolated enum OnboardingDemo {
    static func command(port: Int) -> String {
        "docker run -d -p 127.0.0.1:\(port):80 nginx"
    }

    static func portMapping(port: Int) -> String { "127.0.0.1:\(port):80" }
    static func containerName(port: Int) -> String { "dory-welcome-\(port)" }
    static func url(port: Int) -> String { "http://127.0.0.1:\(port)" }
}

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    enum Step { case welcome, starting, demo, ready }

    @State private var step: Step = .welcome
    @State private var demoBusy = false
    @State private var demoError: String?
    @State private var demoURL: String?
    @State private var demoPort: Int?
    @State private var waited = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            card
                .frame(width: 460)
                .background(p.bgWindow, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(p.borderStrong))
                .shadow(color: .black.opacity(0.5), radius: 35, y: 30)
        }
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 0) {
            logo.padding(.bottom, 18)
            switch step {
            case .welcome: welcomeStep
            case .starting: startingStep
            case .demo: demoStep
            case .ready: readyStep
            }
        }
        .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 28)
    }

    private var logo: some View {
        DoryLogo(size: 60, corner: 18)
            .shadow(color: p.accent.opacity(0.28), radius: 11, y: 8)
    }

    // MARK: Step 1 — Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Text("Run containers on Mac\nwith one shared engine")
                .font(.system(size: 21, weight: .heavy)).foregroundStyle(p.text)
                .multilineTextAlignment(.center).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Text("A self-contained Mac-native engine for Docker, Compose, and Kubernetes. One shared Linux VM — and your tools just work.")
                .font(.system(size: 13)).foregroundStyle(p.text2).multilineTextAlignment(.center).lineSpacing(3)
                .padding(.bottom, 22)

            VStack(spacing: 12) {
                feature(.shield, p.green, p.greenWeak, "One shared Linux engine", "All containers share one managed VM.")
                feature(.eye, p.accentText, p.accentWeak, "Bundled docker, Compose & kubectl", "Dory ships the tools and points them at its engine.")
                feature(.networks, p.amber, p.amberWeak, "Automatic *.dory.local domains", "Every container on a real HTTPS URL.")
            }
            .padding(.bottom, 24)

            primaryButton("Get started", id: "onboarding-start") { step = .starting }
            skipButton.padding(.top, 9)
        }
    }

    // MARK: Step 2 — Engine bootstrap

    private var startingStep: some View {
        VStack(spacing: 0) {
            Text("Starting the Dory engine").font(.system(size: 19, weight: .heavy)).foregroundStyle(p.text)
                .padding(.bottom, 6)
            Text(store.sharedVMStatus.isEmpty ? "Provisioning your engine…" : store.sharedVMStatus)
                .font(.system(size: 13)).foregroundStyle(p.text2).multilineTextAlignment(.center)
                .padding(.bottom, 22)

            ProgressView().controlSize(.large).padding(.bottom, 22)

            Text("Dory.app already includes the engine, kernel, networking, Docker, Compose, and kubectl. First launch extracts and starts them.")
                .font(.system(size: 11.5)).foregroundStyle(p.text3).multilineTextAlignment(.center)
                .padding(.bottom, 18)

            if waited {
                primaryButton("Continue", id: "onboarding-continue") { step = .demo }
            }
            skipButton.padding(.top, 9)
        }
        .onChange(of: store.engineRunning) { _, running in if running { step = .demo } }
        .task {
            if store.engineRunning { step = .demo; return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            waited = true
        }
    }

    // MARK: Step 3 — First container

    private var demoStep: some View {
        VStack(spacing: 0) {
            Text("Run your first container").font(.system(size: 19, weight: .heavy)).foregroundStyle(p.text)
                .padding(.bottom, 6)
            Text("Launch a demo web app in one click — or paste the command into your own terminal.")
                .font(.system(size: 13)).foregroundStyle(p.text2).multilineTextAlignment(.center).lineSpacing(3)
                .padding(.bottom, 18)

            if let demoPort {
                commandRow(OnboardingDemo.command(port: demoPort)).padding(.bottom, 18)
            } else {
                Text("Finding an available localhost port…")
                    .font(.system(size: 12.5)).foregroundStyle(p.text3).padding(.bottom, 18)
            }

            if let url = demoURL, let dest = URL(string: url) {
                Link(destination: dest) {
                    HStack(spacing: 8) {
                        Glyph(glyph: .networks, size: 14, color: p.green)
                        Text(url).font(.mono(13, weight: .medium)).foregroundStyle(p.accentText)
                        Spacer(minLength: 0)
                        Text("Open ↗").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(p.greenWeak, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).padding(.bottom, 14)
                primaryButton("Next", id: "onboarding-next") { step = .ready }
            } else {
                if let demoError { Text(demoError).font(.system(size: 12)).foregroundStyle(p.red).padding(.bottom, 12) }
                primaryButton(demoBusy ? "Starting…" : "Run a demo app", id: "onboarding-demo", busy: demoBusy) { runDemo() }
                Button { step = .ready } label: {
                    Text("I'll do it myself").font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.text3)
                }
                .buttonStyle(.plain).padding(.top, 10)
            }
        }
        .onAppear { prepareDemoPort() }
    }

    // MARK: Step 4 — Ready

    private var readyStep: some View {
        VStack(spacing: 0) {
            Text("You're all set").font(.system(size: 20, weight: .heavy)).foregroundStyle(p.text)
                .padding(.bottom, 6)
            Text("Dory's bundled tools and Docker context point at the engine — nothing else to install.")
                .font(.system(size: 13)).foregroundStyle(p.text2).multilineTextAlignment(.center)
                .padding(.bottom, 20)

            VStack(spacing: 10) {
                proofRow("docker CLI + Compose configured")
                proofRow("kubectl ready when you enable Kubernetes")
                proofRow("*.dory.local domains active")
            }
            .padding(.bottom, 24)

            primaryButton("Open Dory", id: "onboarding-finish") { store.completeOnboarding() }
        }
    }

    // MARK: Actions

    private func runDemo() {
        let port = AppStore.allocateFreePort()
        guard port > 0 else {
            demoError = "Dory could not find an available localhost port. Try again."
            return
        }
        demoPort = port
        demoBusy = true
        demoError = nil
        Task {
            let error = await store.createContainer(
                name: OnboardingDemo.containerName(port: port),
                image: "nginx",
                ports: [OnboardingDemo.portMapping(port: port)],
                env: [:]
            )
            demoBusy = false
            if let error {
                demoError = error
            } else {
                demoURL = OnboardingDemo.url(port: port)
            }
        }
    }

    private func prepareDemoPort() {
        guard demoPort == nil else { return }
        let port = AppStore.allocateFreePort()
        if port > 0 { demoPort = port }
    }

    // MARK: Pieces

    private var skipButton: some View {
        Button { store.completeOnboarding() } label: {
            Text("Skip setup").font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.text3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding-skip")
    }

    private func primaryButton(_ title: String, id: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(p.accent.opacity(busy ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).disabled(busy).accessibilityIdentifier(id)
    }

    private func feature(_ glyph: DoryGlyph, _ tint: Color, _ background: Color, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Glyph(glyph: glyph, size: 17, color: tint)
                .frame(width: 34, height: 34)
                .background(background, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer(minLength: 0)
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 10) {
            Text(command).font(.mono(12.5, weight: .regular)).foregroundStyle(p.monoText)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Glyph(glyph: .plus, size: 13, color: p.text3)
            }
            .buttonStyle(.plain).help("Copy")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(p.monoBg, in: RoundedRectangle(cornerRadius: 9))
    }

    private func proofRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            Glyph(glyph: .shield, size: 14, color: p.green)
                .frame(width: 26, height: 26)
                .background(p.greenWeak, in: RoundedRectangle(cornerRadius: 7))
            Text(title).font(.system(size: 13)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
        }
    }
}

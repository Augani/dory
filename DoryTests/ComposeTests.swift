import Testing
import Foundation
@testable import Dory

struct ComposeTests {
    // MARK: Interpolation

    @Test func interpolatesBasicVariables() {
        let vars = ["NAME": "web", "PORT": "8080"]
        #expect(ComposeInterpolation.interpolate("$NAME:${PORT}", variables: vars) == "web:8080")
    }

    @Test func interpolatesDefaults() {
        #expect(ComposeInterpolation.interpolate("${MISSING:-fallback}", variables: [:]) == "fallback")
        #expect(ComposeInterpolation.interpolate("${SET:-fallback}", variables: ["SET": "x"]) == "x")
        #expect(ComposeInterpolation.interpolate("${EMPTY:-fb}", variables: ["EMPTY": ""]) == "fb")
        #expect(ComposeInterpolation.interpolate("${EMPTY-fb}", variables: ["EMPTY": ""]) == "")
    }

    @Test func escapesDoubleDollar() {
        #expect(ComposeInterpolation.interpolate("$$HOME", variables: ["HOME": "x"]) == "$HOME")
    }

    @Test func parsesDotEnv() {
        let env = ComposeInterpolation.parseDotEnv("# comment\nFOO=bar\nQUOTED=\"hello world\"\r\nCRLF=value\r\n")
        #expect(env["FOO"] == "bar")
        #expect(env["QUOTED"] == "hello world")
        #expect(env["CRLF"] == "value")
    }

    // MARK: Dependency graph

    @Test func ordersDependenciesFirst() throws {
        let graph = DependencyGraph(dependencies: ["web": ["api"], "api": ["db", "cache"], "db": [], "cache": []])
        let order = try graph.topologicalOrder()
        #expect(order.firstIndex(of: "db")! < order.firstIndex(of: "api")!)
        #expect(order.firstIndex(of: "cache")! < order.firstIndex(of: "api")!)
        #expect(order.firstIndex(of: "api")! < order.firstIndex(of: "web")!)
    }

    @Test func detectsCycles() {
        let graph = DependencyGraph(dependencies: ["a": ["b"], "b": ["a"]])
        #expect(throws: ComposeGraphError.self) { try graph.topologicalOrder() }
    }

    @Test func detectsUnknownDependency() {
        let graph = DependencyGraph(dependencies: ["a": ["ghost"]])
        #expect(throws: ComposeGraphError.self) { try graph.topologicalOrder() }
    }

    // MARK: Duration parsing

    @Test func parsesDurations() {
        #expect(ComposeParser.duration("10s") == 10)
        #expect(ComposeParser.duration("1m30s") == 90)
        #expect(ComposeParser.duration("500ms") == 0.5)
        #expect(ComposeParser.duration("2h") == 7200)
    }

    // MARK: Full project parse

    let compose = """
    services:
      web:
        image: ${WEB_IMAGE:-nginx:alpine}
        ports: ["${WEB_PORT:-8080}:80"]
        depends_on:
          api:
            condition: service_started
          db:
            condition: service_healthy
      api:
        image: dory/api:latest
        environment:
          DATABASE_URL: postgres://db:5432/app
        depends_on: [db, cache]
      db:
        image: postgres:16
        healthcheck:
          test: ["CMD", "pg_isready"]
          interval: 5s
          retries: 5
          start_period: 20s
      cache:
        image: redis:7-alpine
    """

    @Test func parsesProjectWithStartOrderAndConditions() throws {
        let project = try ComposeParser.parse(compose, projectName: "demo", variables: ["WEB_PORT": "9090"])
        #expect(project.services.count == 4)

        let web = project.service(named: "web")
        #expect(web?.image == "nginx:alpine")
        #expect(web?.ports == ["9090:80"])
        #expect(web?.dependsOn.contains(ComposeDependency(service: "db", condition: .healthy)) == true)
        #expect(web?.dependsOn.contains(ComposeDependency(service: "api", condition: .started)) == true)

        let api = project.service(named: "api")
        #expect(api?.environment["DATABASE_URL"] == "postgres://db:5432/app")
        #expect(Set(api?.dependsOn.map(\.service) ?? []) == ["db", "cache"])

        let db = project.service(named: "db")
        #expect(db?.healthcheck?.interval == 5)
        #expect(db?.healthcheck?.retries == 5)
        #expect(db?.healthcheck?.startPeriod == 20)

        let order = try project.startOrder()
        #expect(order.firstIndex(of: "db")! < order.firstIndex(of: "api")!)
        #expect(order.firstIndex(of: "cache")! < order.firstIndex(of: "api")!)
        #expect(order.firstIndex(of: "api")! < order.firstIndex(of: "web")!)
        #expect(order.firstIndex(of: "db")! < order.firstIndex(of: "web")!)
    }

    @Test func parsesComposeProfilesEnvironment() {
        #expect(ComposeParser.activeProfiles(from: nil).isEmpty)
        #expect(ComposeParser.activeProfiles(from: "debug, frontend,,observability ") == Set([
            "debug", "frontend", "observability",
        ]))
        #expect(ComposeParser.activeProfiles(from: "*") == Set(["*"]))
    }

    @Test func filtersServicesByActiveProfiles() throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
          debug:
            image: busybox:latest
            profiles: [debug]
          metrics:
            image: prom/prometheus:latest
            profiles: [debug, observability]
          frontend:
            image: dory/frontend:latest
            profiles: frontend
        """

        let defaultProject = try ComposeParser.parse(yaml, projectName: "demo")
        #expect(defaultProject.services.map(\.name) == ["web"])

        let debugProject = try ComposeParser.parse(yaml, projectName: "demo", activeProfiles: ["debug"])
        #expect(debugProject.services.map(\.name) == ["debug", "metrics", "web"])

        let allProject = try ComposeParser.parse(yaml, projectName: "demo", activeProfiles: ["*"])
        #expect(allProject.services.map(\.name) == ["debug", "frontend", "metrics", "web"])
    }

    @Test func mergesComposeFilesWithDockerOverrideRules() throws {
        let base = """
        services:
          web:
            image: nginx:1
            command: ["serve", "old"]
            ports: ["80:80"]
            dns: ["1.1.1.1"]
            environment:
              FOO: base
              BAR: base
            volumes:
              - ./base:/app:ro
              - ./cache:/cache
          db:
            image: postgres:16
        networks:
          front: {}
        volumes:
          data: {}
        """
        let override = """
        services:
          web:
            image: nginx:2
            command: ["serve", "new"]
            ports: ["8080:80"]
            dns: ["8.8.8.8"]
            environment:
              BAR: override
              BAZ: override
            volumes:
              - ./override:/app:rw
              - ./logs:/logs
          worker:
            image: busybox:latest
        networks:
          back: {}
        volumes:
          logs: {}
        """

        let project = try ComposeParser.parse([base, override], projectName: "demo")

        #expect(project.services.map(\.name) == ["db", "web", "worker"])
        #expect(project.networks == ["back", "front"])
        #expect(project.volumes == ["data", "logs"])

        let web = try #require(project.service(named: "web"))
        #expect(web.image == "nginx:2")
        #expect(web.command == ["serve", "new"])
        #expect(web.ports == ["80:80", "8080:80"])
        #expect(web.dns == ["1.1.1.1", "8.8.8.8"])
        #expect(web.environment == [
            "FOO": "base",
            "BAR": "override",
            "BAZ": "override",
        ])
        #expect(web.volumes == ["./override:/app:rw", "./cache:/cache", "./logs:/logs"])
    }

    @Test func mergesEnvironmentSequenceAndMappingOverrides() throws {
        let base = """
        services:
          web:
            image: nginx:alpine
            environment:
              - FOO=base
              - BAR=base
        """
        let override = """
        services:
          web:
            environment:
              BAR: override
              BAZ: override
        """

        let project = try ComposeParser.parse([base, override], projectName: "demo")
        #expect(project.service(named: "web")?.environment == [
            "FOO": "base",
            "BAR": "override",
            "BAZ": "override",
        ])
    }

    @Test func resolvesComposeOverrideFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = directory.appendingPathComponent("compose.yaml")
        let override = directory.appendingPathComponent("compose.override.yaml")
        let prod = directory.appendingPathComponent("compose.prod.yaml")
        try "services: {}".write(to: base, atomically: true, encoding: .utf8)
        try "services: {}".write(to: override, atomically: true, encoding: .utf8)
        try "services: {}".write(to: prod, atomically: true, encoding: .utf8)

        #expect(AppStore.composeFileURLs(for: base, variables: [:]) == [base, override])
        #expect(AppStore.composeFileURLs(for: base, variables: [
            "COMPOSE_FILE": "compose.yaml:compose.prod.yaml",
        ]) == [base, prod])
    }

    @Test func parsesServiceNetworksFromListAndMapping() throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
            networks: [front-tier]
          api:
            image: dory/api:latest
            networks:
              back-tier:
                aliases: [api.internal]
              front-tier: {}
        networks:
          front-tier: {}
          back-tier: {}
        """

        let project = try ComposeParser.parse(yaml, projectName: "demo")

        #expect(project.networks == ["back-tier", "front-tier"])
        #expect(project.service(named: "web")?.networks == ["front-tier"])
        #expect(project.service(named: "api")?.networks == ["back-tier", "front-tier"])
    }

    @Test func parsesCommonServiceCreateOptions() throws {
        let yaml = """
        services:
          dev:
            image: dory/dev:latest
            command: ["sleep", "infinity"]
            entrypoint: ["/usr/bin/env"]
            hostname: devbox
            domainname: local.test
            user: "1000:1000"
            working_dir: /workspace
            tty: true
            stdin_open: true
            init: true
            read_only: true
            privileged: true
            cap_add: [NET_ADMIN, SYS_PTRACE]
            cap_drop: [MKNOD]
            dns: ["1.1.1.1"]
            dns_opt: ["ndots:0"]
            dns_search: [dory.local]
            extra_hosts: ["host.docker.internal:host-gateway"]
            group_add: ["staff"]
            network_mode: none
            tmpfs:
              /tmp: rw,noexec
            sysctls:
              net.ipv4.ip_forward: "1"
            security_opt: ["no-new-privileges:true"]
            storage_opt:
              size: 20G
            logging:
              driver: json-file
              options:
                max-size: 10m
            ulimits:
              nofile:
                soft: 1024
                hard: 2048
              nproc: 4096
            healthcheck:
              test: curl -f http://localhost/health || exit 1
              interval: 2s
              timeout: 500ms
              retries: 4
              start_period: 1m
              start_interval: 1s
            stop_signal: SIGTERM
            stop_grace_period: 15s
            shm_size: 64m
            mem_limit: 512m
            mem_reservation: 256m
            memswap_limit: 1g
            mem_swappiness: 10
            oom_kill_disable: true
            oom_score_adj: 200
            pids_limit: 128
            ipc: host
            pid: host
            userns_mode: host
            uts: host
            runtime: runc
            isolation: default
            links: ["redis:redis"]
            volumes_from: ["parent:ro"]
        """

        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let service = try #require(project.service(named: "dev"))

        #expect(service.command == ["sleep", "infinity"])
        #expect(service.entrypoint == ["/usr/bin/env"])
        #expect(service.hostname == "devbox")
        #expect(service.domainname == "local.test")
        #expect(service.user == "1000:1000")
        #expect(service.workingDir == "/workspace")
        #expect(service.tty)
        #expect(service.stdinOpen)
        #expect(service.initProcessEnabled == true)
        #expect(service.readOnly == true)
        #expect(service.privileged == true)
        #expect(service.capAdd == ["NET_ADMIN", "SYS_PTRACE"])
        #expect(service.capDrop == ["MKNOD"])
        #expect(service.dns == ["1.1.1.1"])
        #expect(service.dnsOptions == ["ndots:0"])
        #expect(service.dnsSearch == ["dory.local"])
        #expect(service.extraHosts == ["host.docker.internal:host-gateway"])
        #expect(service.groupAdd == ["staff"])
        #expect(service.networkMode == "none")
        #expect(service.tmpfs["/tmp"] == "rw,noexec")
        #expect(service.sysctls["net.ipv4.ip_forward"] == "1")
        #expect(service.securityOpt == ["no-new-privileges:true"])
        #expect(service.storageOpt["size"] == "20G")
        #expect(service.logging == ComposeLogging(driver: "json-file", options: ["max-size": "10m"]))
        #expect(service.ulimits == [
            DockerUlimit(Name: "nofile", Soft: 1024, Hard: 2048),
            DockerUlimit(Name: "nproc", Soft: 4096, Hard: 4096),
        ])
        #expect(service.healthcheck?.test == ["CMD-SHELL", "curl -f http://localhost/health || exit 1"])
        #expect(service.healthcheck?.interval == 2)
        #expect(service.healthcheck?.timeout == 0.5)
        #expect(service.healthcheck?.retries == 4)
        #expect(service.healthcheck?.startPeriod == 60)
        #expect(service.healthcheck?.startInterval == 1)
        #expect(service.stopSignal == "SIGTERM")
        #expect(service.stopGracePeriod == 15)
        #expect(service.shmSize == 67_108_864)
        #expect(service.memoryLimitBytes == 536_870_912)
        #expect(service.memoryReservationBytes == 268_435_456)
        #expect(service.memorySwapBytes == 1_073_741_824)
        #expect(service.memorySwappiness == 10)
        #expect(service.oomKillDisable == true)
        #expect(service.oomScoreAdj == 200)
        #expect(service.pidsLimit == 128)
        #expect(service.ipcMode == "host")
        #expect(service.pidMode == "host")
        #expect(service.usernsMode == "host")
        #expect(service.utsMode == "host")
        #expect(service.runtimeName == "runc")
        #expect(service.isolation == "default")
        #expect(service.links == ["redis:redis"])
        #expect(service.volumesFrom == ["parent:ro"])
    }
}

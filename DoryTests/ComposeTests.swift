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
        let env = ComposeInterpolation.parseDotEnv("# comment\nFOO=bar\nQUOTED=\"hello world\"\n")
        #expect(env["FOO"] == "bar")
        #expect(env["QUOTED"] == "hello world")
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
}

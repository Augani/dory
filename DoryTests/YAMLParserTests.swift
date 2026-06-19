import Testing
import Foundation
@testable import Dory

struct YAMLParserTests {
    let compose = """
    # A representative multi-service stack
    services:
      web:
        image: nginx:alpine
        ports:
          - "8080:80"
          - "443:443"
        environment:
          NODE_ENV: production
          PORT: "3000"
        depends_on:
          db:
            condition: service_healthy
        command: ["nginx", "-g", "daemon off;"]
      db:
        image: postgres:16
        healthcheck:
          test: ["CMD", "pg_isready"]
          interval: 10s
          retries: 5
    networks:
      default:
        driver: bridge
    """

    @Test func parsesNestedMappingsAndSequences() throws {
        let root = try YAMLParser.parse(compose)
        let web = root["services"]?["web"]
        #expect(web?["image"]?.stringValue == "nginx:alpine")

        let ports = web?["ports"]?.sequenceValue
        #expect(ports?.count == 2)
        #expect(ports?.first?.stringValue == "8080:80")
        #expect(ports?.last?.stringValue == "443:443")

        #expect(web?["environment"]?["NODE_ENV"]?.stringValue == "production")
        #expect(web?["environment"]?["PORT"]?.stringValue == "3000")
    }

    @Test func parsesDependsOnLongForm() throws {
        let root = try YAMLParser.parse(compose)
        let condition = root["services"]?["web"]?["depends_on"]?["db"]?["condition"]
        #expect(condition?.stringValue == "service_healthy")
    }

    @Test func parsesFlowSequences() throws {
        let root = try YAMLParser.parse(compose)
        #expect(root["services"]?["web"]?["command"]?.stringList == ["nginx", "-g", "daemon off;"])
        #expect(root["services"]?["db"]?["healthcheck"]?["test"]?.stringList == ["CMD", "pg_isready"])
    }

    @Test func parsesScalarsWithTypes() throws {
        let root = try YAMLParser.parse(compose)
        let health = root["services"]?["db"]?["healthcheck"]
        #expect(health?["interval"]?.stringValue == "10s")
        #expect(health?["retries"]?.stringValue == "5")
        if case .number(let retries)? = health?["retries"] { #expect(retries == 5) } else { Issue.record("retries not a number") }
        #expect(root["networks"]?["default"]?["driver"]?.stringValue == "bridge")
    }

    @Test func parsesFlowMapping() throws {
        let root = try YAMLParser.parse("env: {A: 1, B: \"two\"}")
        #expect(root["env"]?["A"]?.stringValue == "1")
        #expect(root["env"]?["B"]?.stringValue == "two")
    }
}

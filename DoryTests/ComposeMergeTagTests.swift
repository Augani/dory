import Testing
@testable import Dory

struct ComposeMergeTagTests {
    @Test func overrideReplacesConcatenatedField() throws {
        let base = """
        services:
          web:
            image: nginx:1
            ports: ["8080:80"]
        """
        let override = """
        services:
          web:
            ports: !override ["9090:90"]
        """
        let project = try ComposeParser.parse([base, override], projectName: "demo")
        let web = try #require(project.service(named: "web"))
        #expect(web.ports == ["9090:90"])
    }

    @Test func overrideReplacesKeyedMapping() throws {
        let base = """
        services:
          web:
            image: nginx:1
            environment:
              FOO: base
              BAR: base
        """
        let override = """
        services:
          web:
            environment: !override {BAZ: "only"}
        """
        let project = try ComposeParser.parse([base, override], projectName: "demo")
        let web = try #require(project.service(named: "web"))
        #expect(web.environment == ["BAZ": "only"])
    }

    @Test func resetRemovesKeySetByBase() throws {
        let base = """
        services:
          web:
            image: nginx:1
            ports: ["8080:80"]
        """
        let override = """
        services:
          web:
            ports: !reset null
        """
        let project = try ComposeParser.parse([base, override], projectName: "demo")
        let web = try #require(project.service(named: "web"))
        #expect(web.ports.isEmpty)
    }

    @Test func tagInSingleFileCollapsesToPlainValue() throws {
        let yaml = """
        services:
          web:
            image: nginx:1
            ports: !override ["9090:90"]
        """
        let project = try ComposeParser.parse([yaml], projectName: "demo")
        let web = try #require(project.service(named: "web"))
        #expect(web.ports == ["9090:90"])
    }

    @Test func parserWrapsInlineTagsAndLeavesQuotedStrings() throws {
        #expect(try YAMLParser.scalarOrFlow("!override [a, b]") == .tagged(.override, .sequence([.string("a"), .string("b")])))
        #expect(try YAMLParser.scalarOrFlow("!reset") == .tagged(.reset, .null))
        #expect(try YAMLParser.scalarOrFlow("!reset null") == .tagged(.reset, .null))
        #expect(try YAMLParser.scalarOrFlow("\"!reset\"") == .string("!reset"))
    }
}

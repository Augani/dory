import Testing
@testable import Dory

struct MachineEnvImportTests {
    @Test func defaultsContainAnthropicOnly() {
        #expect(MachineEnvImport.defaultNames == ["ANTHROPIC_API_KEY"])
        #expect(MachineEnvImport.optionalExtras == ["OPENAI_API_KEY", "GH_TOKEN", "HF_TOKEN"])
    }

    @Test func normalizeAlwaysIncludesDefaultFirstAndDedupes() {
        let result = MachineEnvImport.normalize(["GH_TOKEN", "gh_token", "  ", "ANTHROPIC_API_KEY"])
        #expect(result == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
    }

    @Test func normalizeUppercasesAndTrims() {
        #expect(MachineEnvImport.normalize(["  openai_api_key  "]) == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])
    }

    @Test func parseSplitsOnCommasNewlinesAndSpaces() {
        let result = MachineEnvImport.parse("GH_TOKEN, HF_TOKEN\nOPENAI_API_KEY foo_bar")
        #expect(result == ["ANTHROPIC_API_KEY", "GH_TOKEN", "HF_TOKEN", "OPENAI_API_KEY", "FOO_BAR"])
    }

    @Test func serializeRoundTrips() {
        #expect(MachineEnvImport.serialize(["HF_TOKEN", "ANTHROPIC_API_KEY"]) == "ANTHROPIC_API_KEY,HF_TOKEN")
    }
}

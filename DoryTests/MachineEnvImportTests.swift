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

    @Test func dropsInvalidEnvNames() {
        #expect(MachineEnvImport.normalize(["FOO=BAR", "1PATH", "GH_TOKEN", "A B"]) == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
        #expect(MachineEnvImport.parse("FOO=BAR, GH_TOKEN") == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
    }

    @Test func probeCommandEmitsSentinelPerName() {
        let command = MachineEnvImport.probeCommand(for: ["ANTHROPIC_API_KEY", "GH_TOKEN"])
        #expect(command.contains("@@DORYENV@@ANTHROPIC_API_KEY=%s@@DORYENV@@"))
        #expect(command.contains("@@DORYENV@@GH_TOKEN=%s@@DORYENV@@"))
        #expect(command.contains("\"${ANTHROPIC_API_KEY:-}\""))
        #expect(command.contains("\"${GH_TOKEN:-}\""))
    }

    @Test func parseProbeOutputExtractsNonEmptyVars() {
        let output = "noise@@DORYENV@@ANTHROPIC_API_KEY=sk-ant-123@@DORYENV@@@@DORYENV@@GH_TOKEN=@@DORYENV@@tail"
        let vars = MachineEnvImport.parseProbeOutput(output)
        #expect(vars["ANTHROPIC_API_KEY"] == "sk-ant-123")
        #expect(vars["GH_TOKEN"] == nil)
    }

    @Test func parseProbeOutputIgnoresMalformed() {
        #expect(MachineEnvImport.parseProbeOutput("no sentinels here").isEmpty)
        #expect(MachineEnvImport.parseProbeOutput("@@DORYENV@@BROKEN_NO_EQ@@DORYENV@@").isEmpty)
    }
}

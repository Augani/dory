import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationDockerAuthorityTests: StrictInventoryTestCase {
    @Test func qualifiedAPIBoundsAndAarch64Normalization() async throws {
        let runtime = StrictMigrationRuntime(
            identifier: "unix:///source.sock",
            daemonID: "source-daemon",
            product: "OrbStack"
        )
        runtime.version["Arch"] = "aarch64"
        runtime.info["Architecture"] = "aarch64"

        for version in ["1.40", "1.55"] {
            runtime.version["ApiVersion"] = version
            let authority = try await MigrationDockerAuthority.read(from: runtime)
            #expect(authority.apiVersion == version)
            #expect(authority.architecture == "arm64")
            #expect(authority.product == "OrbStack")
            #expect(authority.socketAuthority == "unix:///source.sock")
        }
    }

    @Test func APIsOutsideTheQualifiedRangeFailClosed() async {
        let runtime = StrictMigrationRuntime(
            identifier: "unix:///source.sock",
            daemonID: "source-daemon",
            product: "Docker Desktop"
        )

        for version in ["1.39", "1.56"] {
            runtime.version["ApiVersion"] = version
            await #expect(throws: MigrationDockerAuthorityError.unsupported(
                "Docker API \(version) is outside the qualified 1.40-1.55 contract"
            )) {
                _ = try await MigrationDockerAuthority.read(from: runtime)
            }
        }
    }

    @Test func nonArm64AndIncompleteAuthoritiesFailClosed() async {
        let runtime = StrictMigrationRuntime(
            identifier: "unix:///source.sock",
            daemonID: "source-daemon",
            product: "Colima"
        )
        runtime.version["Arch"] = "amd64"
        runtime.info["Architecture"] = "amd64"
        await #expect(throws: MigrationDockerAuthorityError.unsupported(
            "Apple Silicon v1 requires arm64 source and target engines"
        )) {
            _ = try await MigrationDockerAuthority.read(from: runtime)
        }

        runtime.version["Arch"] = "arm64"
        runtime.info["Architecture"] = "arm64"
        runtime.info["ID"] = ""
        await #expect(throws: MigrationDockerAuthorityError.invalid(
            "one or more identity fields are empty"
        )) {
            _ = try await MigrationDockerAuthority.read(from: runtime)
        }
    }

    @Test func daemonIdentityIgnoresSocketAliasesButAuthorityDoesNot() async throws {
        let first = StrictMigrationRuntime(
            identifier: "unix:///first.sock",
            daemonID: "same-daemon",
            product: "Docker"
        )
        let second = StrictMigrationRuntime(
            identifier: "unix:///second.sock",
            daemonID: "same-daemon",
            product: "Docker"
        )

        let firstAuthority = try await MigrationDockerAuthority.read(from: first)
        let secondAuthority = try await MigrationDockerAuthority.read(from: second)

        #expect(firstAuthority.daemonIdentity == secondAuthority.daemonIdentity)
        #expect(firstAuthority.authorityID != secondAuthority.authorityID)
    }
}

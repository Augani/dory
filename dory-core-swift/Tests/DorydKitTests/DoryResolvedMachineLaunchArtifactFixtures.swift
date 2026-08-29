import DoryOperations
@testable import DorydKit

func resolvedBootLaunchArtifacts(
    reference: DoryVMResolverReference,
    media: DoryBootMedia,
    mutableEvidence: DoryMutableBootMediaProvenanceAuditEvidence? = nil,
    identifier: String = "primary"
) -> [DoryResolvedMachineLaunchArtifact] {
    [DoryResolvedMachineLaunchArtifact(
        resolverReference: reference,
        media: media,
        authorityRevision: 1,
        usages: [DoryResolvedMachineLaunchArtifactUsage(
            kind: .boot,
            identifier: identifier,
            readOnly: media.mutableProvenance == nil
        )],
        mutableProvenanceEvidence: mutableEvidence
    )]
}

func resolvedMutableStorageLaunchArtifact(
    reference: DoryVMResolverReference,
    source: DoryBootMediaSource,
    identifier: String,
    digestCharacter: Character = "9"
) -> DoryResolvedMachineLaunchArtifact {
    let provenance = DoryMutableBootMediaProvenanceReference(
        repositoryIdentity: "fixture-artifact-authority",
        mediaIdentity: reference.namespace + "-" + reference.identifier,
        revision: 1
    )
    return DoryResolvedMachineLaunchArtifact(
        resolverReference: reference,
        media: DoryBootMedia(
            kind: .virtualDisk,
            source: source,
            mutableProvenance: provenance
        ),
        authorityRevision: 1,
        usages: [DoryResolvedMachineLaunchArtifactUsage(
            kind: .storage,
            identifier: identifier,
            readOnly: false
        )],
        mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence(
            receiptIdentity: "fixture-storage-receipt-1",
            provenance: provenance,
            receiptSHA256: String(repeating: String(digestCharacter), count: 64),
            resolverID: "fixture-artifact-authority",
            resolverVersion: 1
        )
    )
}

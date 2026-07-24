import Testing
@testable import CodexSwitch

@Suite("Desktop installable bundle validation")
struct DesktopInstallableBundleValidationTests {
    @Test("Official OpenAI trust is sufficient without patched-bundle evidence")
    func officialTrustIsSufficient() {
        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: .valid,
                patchedBundle: nil
            ) == .valid
        )
    }

    @Test("A complete exact-version locally signed patch is an installable fallback")
    func completeLocalPatchIsInstallable() {
        let evidence = patchedEvidence()

        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: .invalid("OpenAI Team ID mismatch"),
                patchedBundle: evidence
            ) == .valid
        )
        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: .unavailable("Gatekeeper unavailable"),
                patchedBundle: evidence
            ) == .valid
        )
    }

    @Test("Both bundle versions must match exactly")
    func exactVersionIsRequired() {
        let officialFailure: CodexDesktopBundleValidationResult = .invalid(
            "OpenAI trust failed"
        )

        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: officialFailure,
                patchedBundle: patchedEvidence(bundleVersionMatches: false)
            ) == officialFailure
        )
        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: officialFailure,
                patchedBundle: patchedEvidence(shortVersionMatches: false)
            ) == officialFailure
        )
    }

    @Test("Incomplete markers or a non-strict signature cannot use the fallback")
    func completeMarkersAndStrictSignatureAreRequired() {
        let officialFailure: CodexDesktopBundleValidationResult = .invalid(
            "OpenAI trust failed"
        )

        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: officialFailure,
                patchedBundle: patchedEvidence(patchMarkersComplete: false)
            ) == officialFailure
        )
        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: officialFailure,
                patchedBundle: patchedEvidence(strictSignatureValid: false)
            ) == officialFailure
        )
    }

    @Test("The fallback requires a non-OpenAI, non-ad-hoc signing identity")
    func localNonAdHocSignatureIsRequired() {
        let officialFailure: CodexDesktopBundleValidationResult = .invalid(
            "OpenAI trust failed"
        )

        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: officialFailure,
                patchedBundle: patchedEvidence(signatureStatus: .officialOpenAI)
            ) == officialFailure
        )
        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: officialFailure,
                patchedBundle: patchedEvidence(signatureStatus: .adHoc)
            ) == officialFailure
        )
        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: officialFailure,
                patchedBundle: patchedEvidence(signatureStatus: .unreadable)
            ) == officialFailure
        )
    }

    @Test("Cancellation remains authoritative")
    func cancellationRemainsAuthoritative() {
        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: .cancelled,
                patchedBundle: patchedEvidence()
            ) == .cancelled
        )
    }

    @Test("A failed fallback preserves the official validation result")
    func failedFallbackPreservesOfficialResult() {
        let unavailable: CodexDesktopBundleValidationResult = .unavailable(
            "Security subsystem unavailable"
        )

        #expect(
            DesktopInstallableBundleValidationDecision.decide(
                officialValidation: unavailable,
                patchedBundle: nil
            ) == unavailable
        )
    }

    private func patchedEvidence(
        bundleVersionMatches: Bool = true,
        shortVersionMatches: Bool = true,
        patchMarkersComplete: Bool = true,
        strictSignatureValid: Bool = true,
        signatureStatus: CodexDesktopAppSignatureStatus = .nonOpenAISigned
    ) -> DesktopPatchedBundleValidationEvidence {
        DesktopPatchedBundleValidationEvidence(
            bundleVersionMatches: bundleVersionMatches,
            shortVersionMatches: shortVersionMatches,
            patchMarkersComplete: patchMarkersComplete,
            strictSignatureValid: strictSignatureValid,
            signatureStatus: signatureStatus
        )
    }
}

import Security
import Testing
@testable import ContextCore

@Test func remoteKeychainPreservesFailureCodesInsteadOfRequestingSignIn() throws {
    try RemoteVault.check(errSecSuccess)
    try RemoteVault.check(errSecItemNotFound, missingAllowed: true)
    for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement, errSecItemNotFound] {
        do {
            try RemoteVault.check(status)
            Issue.record("Expected a Keychain failure")
        } catch RemoteFailure.keychain(let actual) {
            #expect(actual == status)
        }
    }
    #expect(throws: RemoteFailure.self) {
        try RemoteVault.check(errSecAuthFailed, missingAllowed: true)
    }
}

@Test func remoteKeychainRecoveryCopyIncludesCodeInBothLanguages() {
    let russian = RemoteFailure.keychainDescription(-25293, language: .russian)
    let english = RemoteFailure.keychainDescription(-25293, language: .english)
    #expect(russian.contains("-25293") && russian.contains("Связке ключей"))
    #expect(english.contains("-25293") && english.contains("Keychain"))
    #expect(!english.contains("Sign in to Supabase again"))
}

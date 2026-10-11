import Testing
import RVDomain

/// Adversarial redaction coverage for `ReviewSanitizer.redactCredentials`: spaced
/// assignments, auth schemes, flags, boundary smuggling, case, PEM armor, percent
/// encoding, Unicode obfuscation, and userinfo, each paired with precision probes
/// proving benign lookalikes survive.
@Suite("ReviewSanitizer hardening")
struct ReviewSanitizerTests {
    // MARK: - Spaced KEY=value

    @Test func spacedEqualsRedactsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password = hunter2")
                == "password = [redacted]"
        )
    }

    @Test func gluedEqualsSpacedValueRedactsValueAgain() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password= hunter2")
                == "password=[redacted] [redacted]"
        )
    }

    @Test func spacedKeyGluedValueRedactsWholeToken() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password =hunter2")
                == "password [redacted]"
        )
    }

    @Test func spacedEqualsKeepsFollowingWords() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password = hunter2 extra")
                == "password = [redacted] extra"
        )
    }

    @Test func spacedEqualsMatchesKeyCaseInsensitively() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "API_KEY = hunter2")
                == "API_KEY = [redacted]"
        )
    }

    @Test func spacedColonRedactsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password : hunter2")
                == "password : [redacted]"
        )
    }

    @Test func spacedEqualsWithNonSecretKeyKeepsValue() {
        #expect(ReviewSanitizer.redactCredentials(in: "count = 5") == "count = 5")
    }

    // MARK: - Colon assignment

    @Test func colonAssignmentRedactsValueButKeepsKey() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password:hunter2")
                == "password:[redacted]"
        )
    }

    @Test func spacedColonValueIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "api-key: abc123")
                == "api-key: [redacted]"
        )
    }

    @Test func urlWithPortAndPathSurvives() {
        let url = "https://example.com:8443/path"
        #expect(ReviewSanitizer.redactCredentials(in: url) == url)
    }

    @Test func proseWithColonsSurvives() {
        let prose = "error: file not found"
        #expect(ReviewSanitizer.redactCredentials(in: prose) == prose)
    }

    @Test func fingerprintColonsSurvive() {
        let fingerprint = "shell:git.force-push:origin:main"
        #expect(ReviewSanitizer.redactCredentials(in: fingerprint) == fingerprint)
    }

    // MARK: - Bearer and auth schemes

    @Test func bearerFollowOnIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "Bearer abc123")
                == "Bearer [redacted]"
        )
    }

    @Test func bearerWithTrailingColonStillOwnsFollower() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "Bearer: abc123")
                == "Bearer: [redacted]"
        )
    }

    @Test func gluedAuthorizationBearerStillOwnsFollower() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "Authorization:Bearer abc123")
                == "Authorization:Bearer [redacted]"
        )
    }

    @Test func basicWithAuthorizationContextIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "Authorization: Basic dXNlcjpwYXNz")
                == "Authorization: Basic [redacted]"
        )
    }

    @Test func bareBasicWithoutAuthContextKeepsValue() {
        #expect(ReviewSanitizer.redactCredentials(in: "basic training") == "basic training")
        #expect(ReviewSanitizer.redactCredentials(in: "use Basic auth") == "use Basic auth")
    }

    @Test func digestWithProxyAuthorizationIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "Proxy-Authorization: Digest abc123")
                == "Proxy-Authorization: Digest [redacted]"
        )
    }

    @Test func tokenSchemeWithAuthorizationIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "Authorization: Token abc123")
                == "Authorization: Token [redacted]"
        )
    }

    @Test func challengeRealmWithoutCredentialsSurvives() {
        let challenge = "WWW-Authenticate: Basic realm=\"example\""
        #expect(ReviewSanitizer.redactCredentials(in: challenge) == challenge)
    }

    // MARK: - Secret flags

    @Test func secretFlagOwnsItsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--password hunter2")
                == "--password [redacted]"
        )
    }

    @Test func secretFlagWithInlineEqualsKeepsFlag() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--token=abc")
                == "--token=[redacted]"
        )
    }

    @Test func tokenizeFlagKeepsItsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--tokenize file.txt")
                == "--tokenize file.txt"
        )
    }

    @Test func secretFlagBeforeAnotherFlagKeepsBoth() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--password --verbose")
                == "--password --verbose"
        )
    }

    @Test func suffixedSecretFlagOwnsItsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--client-secret hunter2")
                == "--client-secret [redacted]"
        )
    }

    @Test func pluralSecretFlagOwnsItsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--credentials hunter2")
                == "--credentials [redacted]"
        )
    }

    @Test func bareKeyFlagOwnsItsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--key hunter2")
                == "--key [redacted]"
        )
    }

    @Test func nonSecretFlagsKeepTheirValues() {
        let command = "git push --force origin main"
        #expect(ReviewSanitizer.redactCredentials(in: command) == command)
    }

    // MARK: - Prefix boundaries and case

    @Test func quotedPATIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "\"ghp_exampletoken\"")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func parenthesizedSecretIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "(sk-abc123)")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func commaGluedPATIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "see,ghp_exampletoken!")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func uppercasePATIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "GHP_EXAMPLETOKEN")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func githubServerTokenSiblingIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "ghs_exampletoken")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func lowercaseAWSKeyIDIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "akiaIOSFODNN7EXAMPLE")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func hyphenGluedPATIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "my-ghp_exampletoken")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func hyphenatedWordsNeverMatchShortPrefix() {
        #expect(ReviewSanitizer.redactCredentials(in: "task-list") == "task-list")
        #expect(ReviewSanitizer.redactCredentials(in: "safe-label") == "safe-label")
    }

    @Test func uppercaseShortPrefixProductCodeSurvives() {
        #expect(ReviewSanitizer.redactCredentials(in: "SK-100") == "SK-100")
    }

    // MARK: - PEM armor

    @Test func lowercaseArmorRedactsWholeText() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "key: -----begin rsa private key----- xyz")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func proseMentioningPrivateKeySurvives() {
        let prose = "rotate the private key soon"
        #expect(ReviewSanitizer.redactCredentials(in: prose) == prose)
    }

    @Test func uppercasePEMRedactsWholeText() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "key: -----BEGIN PRIVATE KEY----- MIIEvQ")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    // MARK: - Percent encoding

    @Test func percentEncodedPATIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "%67%68%70%5Fexampletoken")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func percentEncodedAssignmentIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "%70%61%73%73%77%6F%72%64%3Dhunter2")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func doubleEncodedPATIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "%2567%2568%2570%255Fexampletoken")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func percentEncodedPathSurvives() {
        let encoded = "%2Fhome%2Fuser"
        #expect(ReviewSanitizer.redactCredentials(in: encoded) == encoded)
    }

    @Test func malformedPercentSurvives() {
        let text = "100%negit discount"
        #expect(ReviewSanitizer.redactCredentials(in: text) == text)
    }

    // MARK: - Unicode obfuscation

    @Test func zeroWidthKeyStillRedactsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "pass\u{200B}word=hunter2")
                == "pass\u{200B}word=[redacted]"
        )
    }

    @Test func fullwidthAssignmentIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "ｐａｓｓｗｏｒｄ＝hunter2")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func nbspacedAssignmentRedactsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password\u{00A0}=\u{00A0}hunter2")
                == "password\u{00A0}=\u{00A0}[redacted]"
        )
    }

    @Test func enDashKeyStillRedactsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "api\u{2013}key=hunter2")
                == "api\u{2013}key=[redacted]"
        )
    }

    // MARK: - Userinfo

    @Test func bareUserinfoIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "admin:s3cret@db.internal")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func emailLikeValueSurvives() {
        let email = "user@example.com"
        #expect(ReviewSanitizer.redactCredentials(in: email) == email)
    }

    @Test func schemeUserinfoDirectlyRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "https://user:pass@host/x")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func tripleEncodedBenignValueSurvives() {
        let encoded = "%25252541"
        #expect(ReviewSanitizer.redactCredentials(in: encoded) == encoded)
    }

    @Test func lowercaseHexEncodedPATIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "%67%68%70%5fexampletoken")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func ideographicSpaceTokenizesLikeASpace() {
        let text = "pass\u{3000}word=hunter2"
        #expect(ReviewSanitizer.redactCredentials(in: text) == text)
        #expect(
            ReviewSanitizer.redactCredentials(in: "password\u{3000}=\u{3000}hunter2")
                == "password\u{3000}=\u{3000}[redacted]"
        )
    }

    @Test func sanitizeContextDropsIdeographicSpacedKeyMetadata() {
        let context = ReviewContext(
            repository: RepositoryReviewContext(name: "rv"),
            metadata: ["pass\u{3000}word": "hunter2", "note": "safe-label"]
        )
        let sanitized = ReviewSanitizer.sanitize(context)
        #expect(sanitized.metadata["pass\u{3000}word"] == nil)
        #expect(sanitized.metadata["note"] == "safe-label")
    }

    // MARK: - Key names

    @Test func underscoreKeyNameRedactsPlainValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "OPENAI_KEY=xyz")
                == "OPENAI_KEY=[redacted]"
        )
    }

    @Test func keySubstringsWithoutUnderscoreSurvive() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "monkey=banana keyboard=us")
                == "monkey=banana keyboard=us"
        )
    }

    // MARK: - Stability and stress

    @Test func placeholderSurvivesResanitization() {
        #expect(
            ReviewSanitizer.redactCredentials(in: ReviewSanitizer.redactedPlaceholder)
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func countAssignmentSurvives() {
        #expect(ReviewSanitizer.redactCredentials(in: "COUNT=2") == "COUNT=2")
    }

    @Test func emptyAndBlankInputsSurvive() {
        #expect(ReviewSanitizer.redactCredentials(in: "") == "")
        #expect(ReviewSanitizer.redactCredentials(in: "   ") == "   ")
    }

    @Test func longTokenWithEmbeddedSecretIsRedacted() {
        let token = String(repeating: "x", count: 5_000) + "/ghp_exampletoken"
            + String(repeating: "y", count: 5_000)
        #expect(
            ReviewSanitizer.redactCredentials(in: token)
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func manyTokenInputStillRedactsTailSecret() {
        let message = "start " + String(repeating: "x ", count: 50_000) + "password=hunter2"
        let redacted = ReviewSanitizer.redactCredentials(in: message)
        #expect(redacted.contains("[redacted]"))
        #expect(redacted.contains("hunter2") == false)
    }

    // MARK: - End to end through sanitize

    @Test func sanitizeShellRedactsFlagValueInSupportingCommand() {
        let shell = ShellAction.effectOnly(
            EffectShell(
                fingerprint: ActionFingerprint(rawValue: "shell:deploy"),
                effects: ActionEffects(),
                resources: .git(
                    remote: RemoteName("origin"),
                    ref: .branch(BranchName("main"))
                ),
                scope: ActionScope(),
                supportingCommand: ShellCommand(rawValue: "deploy --password hunter2")
            )
        )
        let sanitized = ReviewSanitizer.sanitize(shell)
        #expect(sanitized.supportingCommand?.rawValue == "deploy --password [redacted]")
    }

    @Test func sanitizeContextDropsUnderscoreKeyMetadata() {
        let context = ReviewContext(
            repository: RepositoryReviewContext(name: "rv"),
            metadata: ["openai_key": "xyz", "note": "safe-label"]
        )
        let sanitized = ReviewSanitizer.sanitize(context)
        #expect(sanitized.metadata["openai_key"] == nil)
        #expect(sanitized.metadata["note"] == "safe-label")
    }

    // MARK: - Spaced auth headers

    @Test func spacedColonAuthRedactsSchemeCredentials() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "Authorization : Basic dXNlcjpwYXNz")
                == "Authorization : Basic [redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "Authorization : Digest abc123")
                == "Authorization : Digest [redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "Authorization : Token xyz")
                == "Authorization : Token [redacted]"
        )
    }

    // MARK: - Short secret key names

    @Test func shortSecretKeyNamesRedactValues() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "DB_PASS=s3cr3t")
                == "DB_PASS=[redacted]"
        )
        #expect(ReviewSanitizer.redactCredentials(in: "PASS=x") == "PASS=[redacted]")
        #expect(ReviewSanitizer.redactCredentials(in: "PWD=x") == "PWD=[redacted]")
        #expect(ReviewSanitizer.redactCredentials(in: "AUTH=x") == "AUTH=[redacted]")
        #expect(
            ReviewSanitizer.redactCredentials(in: "db-pass = hunter2")
                == "db-pass = [redacted]"
        )
    }

    @Test func bareKeyAssignmentRedactsValue() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "KEY=hunter2")
                == "KEY=[redacted]"
        )
        #expect(ReviewSanitizer.redactCredentials(in: "key:abc") == "key:[redacted]")
    }

    // MARK: - PAT prefix coverage

    @Test func patPrefixesCoverGitLabSlackAndGCP() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "glpat-AbCdEfGhIjKlMnOpQrSt")
                == "[redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "xoxb-1234567890-abcdefghij")
                == "[redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "xoxp-1234567890-token")
                == "[redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "AIzaSyA-abcdefg123456")
                == "[redacted]"
        )
    }

    @Test func patPrefixSiblingsAndUppercaseAKIA() {
        for prefix in ["gho_", "ghu_", "ghr_", "github_pat_"] {
            #expect(
                ReviewSanitizer.redactCredentials(in: "\(prefix)abc123secret")
                    == "[redacted]"
            )
        }
        #expect(
            ReviewSanitizer.redactCredentials(in: "AKIAIOSFODNN7EXAMPLE")
                == "[redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "my_ghp_abc123")
                == "[redacted]"
        )
    }

    // MARK: - Metadata keys

    @Test func sanitizeContextRedactsSecretShapedMetadataKeys() {
        let context = ReviewContext(
            repository: RepositoryReviewContext(name: "rv"),
            metadata: ["ref ghp_abc123": "safe-label", "note": "ok"]
        )
        let sanitized = ReviewSanitizer.sanitize(context)
        #expect(sanitized.metadata["ref [redacted]"] == "safe-label")
        #expect(sanitized.metadata["note"] == "ok")
    }

    // MARK: - Separator and flag variants

    @Test func doubleEqualsAndColonEqualsSeparatorsRedact() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password == hunter2")
                == "password == [redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "password := hunter2")
                == "password := [redacted]"
        )
        // `=>` is itself a glued separator-value, so it redacts with the value.
        #expect(
            ReviewSanitizer.redactCredentials(in: "password => hunter2")
                == "password [redacted] [redacted]"
        )
    }

    @Test func gluedColonValueAndSpacedColonEqualsRedact() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "password :hunter2")
                == "password [redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "password :=hunter2")
                == "password [redacted]"
        )
    }

    @Test func singleDashAndDottedFlagsRedactValues() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "-password hunter2")
                == "-password [redacted]"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "--client.secret hunter2")
                == "--client.secret [redacted]"
        )
    }

    @Test func secretShapedKeyOrTailDropsWholeToken() {
        #expect(ReviewSanitizer.redactCredentials(in: "ghp_abc123=x") == "[redacted]")
        #expect(
            ReviewSanitizer.redactCredentials(in: "event:ghp_abc123") == "[redacted]"
        )
    }

    @Test func emptyUserinfoPartsSurvive() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "https://:pass@host/x")
                == "https://:pass@host/x"
        )
        #expect(
            ReviewSanitizer.redactCredentials(in: "https://user:@host/x")
                == "https://user:@host/x"
        )
    }

    @Test func malformedPercentTripletsSurvive() {
        #expect(ReviewSanitizer.redactCredentials(in: "abc%") == "abc%")
        #expect(ReviewSanitizer.redactCredentials(in: "abc%ff") == "abc%ff")
    }

    @Test func controlCharFoldRedactsAcrossGap() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "pass\u{0}word=x")
                == "pass\u{0}word=[redacted]"
        )
    }

    @Test func uppercasePrivateKeyProseIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "my PRIVATE KEY here") == "[redacted]"
        )
    }

    @Test func percentDecodedWhitespacePieceRedacts() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "zz%20key%3D1") == "[redacted]"
        )
    }

    @Test func nonASCIITripletSurvives() {
        #expect(ReviewSanitizer.redactCredentials(in: "%éX") == "%éX")
    }

    @Test func gluedFlagValueDoesNotOwnFollower() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "--token=x hunter2")
                == "--token=[redacted] hunter2"
        )
    }

    @Test func lowercaseOpenSSHArmorIsRedacted() {
        #expect(
            ReviewSanitizer.redactCredentials(in: "-----begin openssh thing-----")
                == "[redacted]"
        )
    }
}

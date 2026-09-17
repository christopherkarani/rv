import Foundation
import Testing
@testable import RVAnalytics

@Suite("AnalyticsCredentials")
struct AnalyticsCredentialsTests {
    @Test func bundledKeyIsEmptyInOpenTrees() {
        #expect(AnalyticsCredentials.bundledAPIKey.isEmpty)
    }

    @Test func defaultHostIsUSIngest() {
        #expect(AnalyticsCredentials.defaultHost.scheme == "https")
        #expect(AnalyticsCredentials.defaultHost.host == "us.i.posthog.com")
        #expect(
            AnalyticsCredentials.defaultHost
                == AnalyticsCredentials.ingestURL(from: "https://us.i.posthog.com")
        )
    }

    @Test func ingestURLFallsBackToFileRoot() {
        let fallback = AnalyticsCredentials.ingestURL(from: "")
        #expect(fallback.isFileURL)
        #expect(fallback.path == "/")
    }

    @Test func apiKeyReadsOverride() {
        #expect(
            AnalyticsCredentials.apiKey(environment: ["RV_POSTHOG_API_KEY": "phc_override"])
                == "phc_override"
        )
    }

    @Test func emptyOverrideFallsBackToBundled() {
        #expect(
            AnalyticsCredentials.apiKey(environment: ["RV_POSTHOG_API_KEY": ""])
                == AnalyticsCredentials.bundledAPIKey
        )
    }

    @Test func missingOverrideUsesBundled() {
        #expect(AnalyticsCredentials.apiKey(environment: [:]) == AnalyticsCredentials.bundledAPIKey)
    }

    @Test func hostReadsOverride() {
        let host = AnalyticsCredentials.host(
            environment: ["RV_POSTHOG_HOST": "http://127.0.0.1:9"]
        )
        #expect(host.absoluteString == "http://127.0.0.1:9")
    }

    @Test func emptyHostFallsBackToDefault() {
        #expect(
            AnalyticsCredentials.host(environment: ["RV_POSTHOG_HOST": ""])
                == AnalyticsCredentials.defaultHost
        )
    }

    @Test func missingHostUsesDefault() {
        #expect(AnalyticsCredentials.host(environment: [:]) == AnalyticsCredentials.defaultHost)
    }

    @Test func unparsableHostFallsBackToDefault() {
        #expect(
            AnalyticsCredentials.host(environment: ["RV_POSTHOG_HOST": "http://["])
                == AnalyticsCredentials.defaultHost
        )
    }

    @Test func defaultArgumentsMatchProcessEnvironment() {
        #expect(
            AnalyticsCredentials.apiKey()
                == AnalyticsCredentials.apiKey(environment: ProcessInfo.processInfo.environment)
        )
        #expect(
            AnalyticsCredentials.host()
                == AnalyticsCredentials.host(environment: ProcessInfo.processInfo.environment)
        )
    }
}

@Suite("AnalyticsPaths")
struct AnalyticsPathsTests {
    @Test func ownedFilesAreUnderConfigDirectory() {
        let root = URL(fileURLWithPath: "/tmp/rv-analytics-paths", isDirectory: true)
        let paths = AnalyticsPaths(configDirectory: root)
        #expect(paths.configFile.lastPathComponent == "config.json")
        #expect(paths.identityFile.lastPathComponent == "analytics-id")
        #expect(paths.countersFile.lastPathComponent == "analytics-counters.json")
        #expect(paths.installSentFile.lastPathComponent == "analytics-install-sent")
        #expect(paths.hostsFile.lastPathComponent == "analytics-hosts.json")
        #expect(Set(paths.uninstallArtifacts) == [
            paths.configFile,
            paths.identityFile,
            paths.countersFile,
            paths.installSentFile,
            paths.hostsFile,
        ])
    }

    @Test func missingHomeIsNil() {
        #expect(AnalyticsPaths.makeFromEnvironment(environment: [:]) == nil)
    }

    @Test func emptyHomeIsNil() {
        #expect(AnalyticsPaths.makeFromEnvironment(environment: ["HOME": ""]) == nil)
    }

    @Test func homeBuildsConfigDirectory() {
        let paths = AnalyticsPaths.makeFromEnvironment(environment: ["HOME": "/tmp/rv-home"])
        #expect(paths?.configDirectory.path == "/tmp/rv-home/.config/rv")
    }
}

@Suite("AnalyticsPropertyValue")
struct AnalyticsPropertyValueTests {
    @Test func jsonObjectCases() {
        #expect(AnalyticsPropertyValue.string("v").jsonObject as? String == "v")
        #expect(AnalyticsPropertyValue.int(3).jsonObject as? Int == 3)
        #expect(AnalyticsPropertyValue.bool(false).jsonObject as? Bool == false)
        #expect(AnalyticsPropertyValue.strings(["a"]).jsonObject as? [String] == ["a"])
    }

    @Test func payloadDefaultsAndNames() {
        let payload = AnalyticsPayload(event: AnalyticsPayload.installEvent, distinctID: "id")
        #expect(payload.properties.isEmpty)
        #expect(AnalyticsPayload.installEvent == "install")
        #expect(AnalyticsPayload.dailyActiveEvent == "daily_active")
    }

    @Test func transportErrorsAreEquatable() {
        #expect(AnalyticsTransportError.httpStatus(500) == .httpStatus(500))
        #expect(AnalyticsTransportError.httpStatus(500) != .httpStatus(404))
        #expect(AnalyticsTransportError.encodingFailed == .encodingFailed)
    }
}

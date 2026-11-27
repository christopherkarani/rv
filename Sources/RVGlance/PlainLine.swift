import Foundation
import RVDomain
import RVIPC

// The plain-English line (K5): one short sentence under a stopped command
// saying what it would have done. It explains a decision rvd already made;
// it never makes one. The request is built from an event that is already
// decided, and the line is a display-only string: nothing in rvd, policy
// or IPC imports this file's types.
//
// Tense: every line describes the action's effect in the conditional
// ("Would throw away uncommitted changes"), whatever the verdict, so a
// line reads the same under a stop and under anything shown later.

/// What an explainer is shown: the action, never the reasons for its
/// verdict beyond the rule id hint.
public struct PlainRequest: Sendable, Hashable {
    /// The verdict as the row shows it. Explainers ignore it on purpose: the
    /// line is a function of the action, so it cannot argue with the verdict.
    public enum Outcome: String, Sendable, Hashable {
        case ran
        case stopped
    }

    public var host: HookHost
    public var tool: LiveTool
    /// Redacted command (Bash) or path (file tools). May be empty.
    public var text: String
    public var outcome: Outcome
    /// Rule id (`core.git:reset-hard`), used only as a hint.
    public var rule: String?

    public init(host: HookHost, tool: LiveTool, text: String, outcome: Outcome, rule: String? = nil) {
        self.host = host
        self.tool = tool
        self.text = text
        self.outcome = outcome
        self.rule = rule
    }

    public init(_ decision: LiveDecision) {
        self.init(
            host: decision.host, tool: decision.tool, text: decision.command ?? decision.path ?? "",
            outcome: decision.verdict == .allowed ? .ran : .stopped, rule: decision.rule)
    }

    public init(_ stop: GlanceStop) {
        self.init(host: stop.host, tool: stop.tool, text: stop.action, outcome: .stopped, rule: stop.rule)
    }
}

/// One line of display text. Display only: it has no verdict in it.
public struct PlainLine: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// `PlainTemplate`: deterministic, always available.
        case template
        /// The on-device language model, after `PlainSanitizer`.
        case onDevice
    }

    /// Longest line, in characters, ellipsis included.
    public static let maxLength = 80

    public var text: String
    public var source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }
}

public protocol PlainExplainer: Sendable {
    func explain(_ request: PlainRequest) async -> PlainLine
}

/// Uses the template outright when it recognises the action (its table is
/// exact where it applies); otherwise tries `primary` for up to `timeout`,
/// and uses the template when it is late, or when its on-device text does
/// not pass `PlainSanitizer`.
public struct PlainFallback<Primary: PlainExplainer>: PlainExplainer {
    public static var defaultTimeout: Duration { .milliseconds(1_500) }

    public let primary: Primary
    public let timeout: Duration

    public init(primary: Primary, timeout: Duration = Self.defaultTimeout) {
        self.primary = primary
        self.timeout = timeout
    }

    public func explain(_ request: PlainRequest) async -> PlainLine {
        let template = PlainTemplate.line(for: request)
        guard !PlainTemplate.recognises(request), let line = await firstWithin(request) else { return template }
        switch line.source {
        case .template:
            return line
        case .onDevice:
            // Sanitized again here: a primary that skipped it still cannot
            // put a decision claim or a second line on screen.
            guard let text = PlainSanitizer.clean(line.text) else { return template }
            return PlainLine(text: text, source: .onDevice)
        }
    }

    /// The primary's line, or nil when the timeout wins. The primary runs
    /// unstructured so one that ignores cancellation cannot hold the line.
    private func firstWithin(_ request: PlainRequest) async -> PlainLine? {
        let (stream, continuation) = AsyncStream.makeStream(of: PlainLine?.self)
        let primary = primary
        let timeout = timeout
        let work = Task {
            continuation.yield(await primary.explain(request))
        }
        let clock = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }
        var first: PlainLine?
        for await value in stream {
            first = value
            break
        }
        continuation.finish()
        work.cancel()
        clock.cancel()
        return first
    }
}

/// Shared text helpers for lines.
public enum PlainText {
    /// One line: whitespace runs collapsed, at most `max` characters with an
    /// ellipsis when cut.
    public static func clamp(_ text: String, max: Int = PlainLine.maxLength) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > max else { return flat }
        let cut = flat.prefix(Swift.max(0, max - 1)).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }
}

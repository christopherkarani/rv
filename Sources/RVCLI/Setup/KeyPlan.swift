import Foundation
import RVDomain
import RVIsolation
import RVPresentation

/// A found key rv can keep with no flags: it has a value and rv knows the
/// one host it may be sent to.
struct KeyOffer: Sendable, Equatable {
    var name: String
    var sightings: [KeySighting]
    var value: FoundKeyValue
    var gateway: KnownSecretDefaults.Gateway

    /// Where the row says the key is: a shell file first (the line a
    /// person can act on), else wherever it was seen first.
    var shownSighting: KeySighting? {
        sightings.first { if case .shellFile = $0 { true } else { false } } ?? sightings.first
    }
}

/// A key agents can still read after rv keeps it: the shell line that
/// exports it, or the environment it came from.
struct KeyExposure: Sendable, Equatable {
    var name: String
    var sighting: KeySighting
}

/// What `rv setup` offers, decided from the scan and what rv already keeps.
/// Pure. A name rv already keeps is never offered (a found value never
/// replaces a kept one); its shell lines are still named.
struct KeyPlan: Sendable, Equatable {
    var offers: [KeyOffer]
    /// Keys rv already keeps that a shell file or the environment still hands out.
    var keptButExposed: [KeyExposure]

    static func make(
        _ found: [FoundKey], kept: Set<String>,
        gateway: (String) -> KnownSecretDefaults.Gateway? = { KnownSecretDefaults.gateway(for: $0) }
    ) -> KeyPlan {
        var offers: [KeyOffer] = []
        var exposed: [KeyExposure] = []
        for key in found {
            if kept.contains(key.name) {
                exposed += exposures(of: key.name, sightings: key.sightings)
                continue
            }
            guard let value = key.value, let gateway = gateway(key.name) else { continue }
            offers.append(KeyOffer(name: key.name, sightings: key.sightings, value: value, gateway: gateway))
        }
        return KeyPlan(offers: offers, keptButExposed: exposed)
    }

    /// Every shell line that exports the key; the environment only when no
    /// shell file does (then rv cannot say where it is set).
    static func exposures(of name: String, sightings: [KeySighting]) -> [KeyExposure] {
        let lines = sightings.filter { if case .shellFile = $0 { true } else { false } }
        if lines.isEmpty == false { return lines.map { KeyExposure(name: name, sighting: $0) } }
        return sightings.contains(.environment) ? [KeyExposure(name: name, sighting: .environment)] : []
    }

    var isEmpty: Bool { offers.isEmpty && keptButExposed.isEmpty }
}

/// The words of the keys step. Plain text, one idea a line; colour goes on
/// the leading glyph only (`BoxInk.paint`). No line ever holds a value.
enum KeysScreen {
    /// `◆ rv found 2 keys your agents can read`, then one row a key.
    static func found(_ offers: [KeyOffer]) -> String {
        let nameWidth = offers.map(\.name.count).max() ?? 0
        let sources = offers.map { $0.shownSighting.map(\.label) ?? "" }
        let sourceWidth = sources.map(\.count).max() ?? 0
        var text = "◆ rv found \(count(offers.count, "key")) your agents can read\n"
        for (offer, source) in zip(offers, sources) {
            text += "  " + padded(offer.name, nameWidth) + "  " + padded(source, sourceWidth)
                + "  → " + destination(offer.gateway) + "\n"
        }
        return text
    }

    /// The one question. Enter keeps them.
    static func question(_ count: Int) -> String {
        count == 1 ? "  Keep it? ⏎ " : "  Keep them? ⏎ "
    }

    /// What the owner check is asked to approve, and the prompt shows.
    static func ownerSummary(_ offers: [KeyOffer]) -> String {
        "keep \(count(offers.count, "key")) in rv (\(offers.map(\.name).joined(separator: ", ")))"
    }

    static let declined = "  Nothing changed.\n→ rv setup keys\n"
    static let ownerRefused = "  Nothing changed.\n"

    #if canImport(LocalAuthentication)
    static let approved = "  Touch ID · ✓\n"
    #else
    static let approved = "  password · ✓\n"
    #endif

    /// After the move: one `✓` line, a `✕` line for each key not kept, a
    /// `◐` line for each place agents can still read a kept key, and the
    /// command that hands kept keys to a tool.
    static func result(kept: [String], failed: [(name: String, reason: String)], exposures: [KeyExposure]) -> String {
        var text = ""
        if kept.isEmpty == false {
            text += "✓ Kept \(kept.count) · agents get a stand-in, never the key\n"
        }
        for failure in failed {
            text += "✕ \(failure.name) not kept: \(failure.reason)\n"
        }
        text += exposureLines(exposures, kept: false)
        if kept.isEmpty {
            text += "→ rv doctor\n"
        } else {
            text += "→ rv run " + kept.map { "--secret \($0)" }.joined(separator: " ") + " -- <command>\n"
        }
        return text
    }

    /// `◐ ~/.zshrc:12 still exports OPENAI_API_KEY · delete that line`.
    /// rv never edits a shell file: it names the line, never its text.
    static func exposureLines(_ exposures: [KeyExposure], kept: Bool) -> String {
        let suffix = kept ? ", which rv keeps" : ""
        return exposures.map { exposure in
            switch exposure.sighting {
            case .shellFile:
                "◐ \(exposure.sighting.label) still exports \(exposure.name)\(suffix) · delete that line\n"
            case .environment, .login:
                "◐ \(exposure.name) is still in this shell's environment\(suffix) · unset it where you set it\n"
            }
        }.joined()
    }

    /// `rv setup keys` with nothing to keep.
    static func nothingFound(shellFiles: Int) -> String {
        "✓ No keys your agents can read · checked \(count(shellFiles, "shell file")), the environment, gh and vercel\n"
    }

    /// Why `rv setup keys` will not run here. Nothing was read.
    static func refusal(_ gate: KeysGate) -> String? {
        switch gate {
        case .open: nil
        case .noTerminal:
            "✕ rv setup keys needs you at a terminal. Nothing was read or moved.\n"
        case .agent(let host):
            "✕ rv setup keys runs only in your own terminal, not inside \(host.displayName). Nothing was read or moved.\n"
        }
    }

    private static func destination(_ gateway: KnownSecretDefaults.Gateway) -> String {
        let host = URL(string: gateway.upstream)?.host ?? gateway.upstream
        guard gateway.allow.count == 1, case .preset(let preset) = gateway.allow[0] else { return host }
        return host + " · " + preset.rawValue
    }

    private static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

/// Who may move keys. Owner only: a terminal the person is at, and no
/// agent's markers in the environment. The owner check (Touch ID or the
/// login password) still follows the question; this gate decides whether
/// rv even asks.
enum KeysGate: Sendable, Equatable {
    case open
    /// No terminal to ask on: a pipe, a script, an agent's tool call.
    case noTerminal
    /// The environment carries an agent's markers (`CLAUDECODE`, `CODEX_THREAD_ID`, …).
    case agent(HookHost)

    static func decide(interactive: Bool, agents: Set<HookHost>) -> KeysGate {
        if let host = agents.sorted(by: { $0.rawValue < $1.rawValue }).first { return .agent(host) }
        return interactive ? .open : .noTerminal
    }
}

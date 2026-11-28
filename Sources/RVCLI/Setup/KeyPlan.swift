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
    /// Where `value` came from. The found line and the stored description
    /// name this place, never another sighting.
    var source: KeySighting
    var gateway: KnownSecretDefaults.Gateway
}

/// A key agents can still read after rv keeps it: the shell line that
/// exports it, a login file that holds it, or the environment.
struct KeyExposure: Sendable, Equatable {
    var name: String
    var sighting: KeySighting
}

/// What `rv setup` offers, decided from the scan and what rv already keeps.
/// Pure. A name rv already keeps is never offered (a found value never
/// replaces a kept one); its shell lines are still named. A name whose
/// shell file and environment disagree is never offered either.
struct KeyPlan: Sendable, Equatable {
    var offers: [KeyOffer]
    /// Keys rv already keeps that a shell file or the environment still hands out.
    var keptButExposed: [KeyExposure]
    /// Keys whose shell-file value and environment value differ: kept by
    /// neither, named so the owner can choose with `rv secrets add`.
    var conflicts: [FoundKey] = []

    static func make(
        _ found: [FoundKey], kept: Set<String>,
        gateway: (String) -> KnownSecretDefaults.Gateway? = { KnownSecretDefaults.gateway(for: $0) }
    ) -> KeyPlan {
        var plan = KeyPlan(offers: [], keptButExposed: [])
        for key in found {
            if kept.contains(key.name) {
                plan.keptButExposed += exposures(of: key.name, sightings: key.sightings)
                continue
            }
            guard let value = key.value, let source = key.valueSighting, let gateway = gateway(key.name) else {
                continue
            }
            if key.environmentDiffers {
                plan.conflicts.append(key)
                continue
            }
            plan.offers.append(KeyOffer(
                name: key.name, sightings: key.sightings, value: value, source: source, gateway: gateway))
        }
        return plan
    }

    /// Every shell line that exports the key and every login file that
    /// holds it; the environment only when no shell file sets it (then rv
    /// cannot say where it is set).
    static func exposures(of name: String, sightings: [KeySighting]) -> [KeyExposure] {
        let places = sightings.filter { if case .environment = $0 { false } else { true } }
        let fromShell = places.contains { if case .shellFile = $0 { true } else { false } }
        let environment = fromShell == false && sightings.contains(.environment) ? [KeySighting.environment] : []
        return (places + environment).map { KeyExposure(name: name, sighting: $0) }
    }

    var isEmpty: Bool { offers.isEmpty && keptButExposed.isEmpty && conflicts.isEmpty }
}

/// The words of the keys step (v6c "the cut"). Plain text, one idea a
/// line; colour goes on the leading glyph only (`BoxInk.paint`). No line
/// ever holds a value.
enum KeysScreen {
    /// `◆ rv found 2 keys · OPENAI_API_KEY in ~/.zshrc:3 · GITHUB_TOKEN from gh`.
    static func found(_ offers: [KeyOffer]) -> String {
        "◆ rv found \(count(offers.count, "key"))"
            + offers.map { " · \($0.name) \(place($0.source))" }.joined() + "\n"
    }

    /// `in ~/.zshrc:3`, `in the environment`, `from gh`.
    static func place(_ sighting: KeySighting) -> String {
        switch sighting {
        case .shellFile: "in \(sighting.label)"
        case .environment: "in the environment"
        case .login(let tool): "from \(tool)"
        }
    }

    /// Linux only: the question before the password prompt. On macOS the
    /// Touch ID sheet is the question. Enter keeps them.
    static func question(_ count: Int) -> String {
        count == 1 ? "  Keep it? ⏎ " : "  Keep them? ⏎ "
    }

    /// What the owner check is asked to approve, and the prompt shows.
    static func ownerSummary(_ offers: [KeyOffer]) -> String {
        "keep \(count(offers.count, "key")) in rv (\(offers.map(\.name).joined(separator: ", ")))"
    }

    /// A no at the question, a cancelled Touch ID sheet, a refused password.
    static let declined = "  Nothing changed.\n→ rv setup keys\n"

    /// After the move: v6c's line, a `✕` line for each key not kept, a `◐`
    /// line for each place agents can still read a kept key, and the
    /// command that hands kept keys to a tool.
    static func result(kept: [String], failed: [(name: String, reason: String)], exposures: [KeyExposure]) -> String {
        var text = ""
        if kept.count == 1 {
            text += "✓ Kept. Your agents can use it. They can't leak it.\n"
        } else if kept.isEmpty == false {
            text += "✓ Kept. Your agents can use them. They can't leak them.\n"
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
            case .login(let tool):
                "◐ \(tool)'s login file still holds \(exposure.name)\(suffix) · agents can read it\n"
            case .environment:
                "◐ \(exposure.name) is still in this shell's environment\(suffix) · unset it where you set it\n"
            }
        }.joined()
    }

    /// A name whose file and environment values differ: rv keeps neither.
    static func conflictLines(_ conflicts: [FoundKey]) -> String {
        conflicts.map { key in
            let file = key.valueSighting.map(\.label) ?? "a shell file"
            return "◐ \(key.name) in \(file) differs from the environment's · kept neither · rv secrets add \(key.name)\n"
        }.joined()
    }

    /// `rv setup keys` with nothing to keep.
    static func nothingFound(shellFiles: Int) -> String {
        "✓ No keys your agents can read · checked \(count(shellFiles, "shell file")), the environment, gh and vercel\n"
    }

    /// Why `rv setup keys` will not run here. Nothing was read.
    static func refusal(_ gate: KeysGate) -> String? {
        switch gate {
        case .open, .automation: nil
        case .noTerminal:
            "✕ rv setup keys needs you at a terminal. Nothing was read or moved.\n"
        case .agent(let host):
            "✕ rv setup keys runs only in your own terminal, not inside \(host.displayName). Nothing was read or moved.\n"
        }
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

/// How the owner is asked on this platform. macOS: the Touch ID sheet is
/// the one question (rvd shows it, and it may fall back to the password,
/// so no method is claimed afterwards). Linux: one question, then the
/// login password, which is always what was used.
struct KeysPromptStyle: Sendable, Equatable {
    var asksFirst: Bool
    var approvedLine: String?

    static let touchIDSheet = KeysPromptStyle(asksFirst: false, approvedLine: nil)
    static let questionThenPassword = KeysPromptStyle(asksFirst: true, approvedLine: "  password · ✓\n")

    #if canImport(LocalAuthentication)
    static let platform = touchIDSheet
    #else
    static let platform = questionThenPassword
    #endif
}

/// Who may move keys. Owner only: a terminal the person is at, and no
/// agent's markers in the environment. The owner check (Touch ID or the
/// login password) still follows; this gate decides whether rv even asks.
enum KeysGate: Sendable, Equatable {
    case open
    /// No terminal to ask on: a pipe, a script, an agent's tool call.
    case noTerminal
    /// The environment carries an agent's markers (`CLAUDECODE`, `CODEX_THREAD_ID`, …).
    case agent(HookHost)
    /// `CI` is set: automation after `rv setup` is never asked anything.
    case automation

    static func decide(interactive: Bool, agents: Set<HookHost>, ci: Bool = false) -> KeysGate {
        if let host = agents.sorted(by: { $0.rawValue < $1.rawValue }).first { return .agent(host) }
        if ci { return .automation }
        return interactive ? .open : .noTerminal
    }
}

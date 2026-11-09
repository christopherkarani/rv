import Foundation

/// sudo short options whose value is the next word (`-u root`, `-p prompt`).
/// A superset of what any one sudo build accepts: consuming a word that was
/// really argv0 only moves argv0 later, which never hides an operand.
private let sudoValueLetters: Set<Character> = [
    "u", "g", "h", "p", "C", "U", "T", "r", "t", "D", "R", "c",
]

/// True when a short sudo option (or cluster ending in one) takes the next
/// word as its value.
func sudoFlagTakesValue(_ option: String) -> Bool {
    shortClusterConsumesValue(option, valueLetters: sudoValueLetters)
}

/// env options whose value is the next word (`-u NAME`, `-C DIR`, `-S STR`).
private let envValueLetters: Set<Character> = ["u", "C", "S", "P"]
private let envValueLongFlags: Set<String> = ["--unset", "--chdir", "--split-string", "--argv0"]

/// True when an env option takes the next word as its value.
func envFlagTakesValue(_ option: String) -> Bool {
    envValueLongFlags.contains(option) || shortClusterConsumesValue(option, valueLetters: envValueLetters)
}

func stripSudo(_ text: String) -> String? {
    let (word, rest) = firstWord(text)
    guard basename(word) == "sudo" else { return nil }
    var remaining = rest
    while !remaining.isEmpty {
        let (option, after) = firstWord(remaining)
        guard option.hasPrefix("-") else { break }
        if option == "--" {
            remaining = after
            break
        }
        if option.hasPrefix("--") {
            return nil
        }
        remaining = after
        if sudoFlagTakesValue(option) {
            guard remaining.isEmpty == false else { return nil }
            remaining = firstWord(remaining).rest
        }
    }
    return remaining.isEmpty ? nil : remaining
}

func stripEnv(_ text: String) -> String? {
    let (word, rest) = firstWord(text)
    guard basename(word) == "env" else { return nil }
    var remaining = rest
    while !remaining.isEmpty {
        let (option, after) = firstWord(remaining)
        // `-S STR` is the command itself, split by env: the view shows its
        // words, so skipping one would hide the real argv0.
        if envFlagTakesValue(option), option.contains("S") == false, option != "--split-string" {
            guard after.isEmpty == false else { return nil }
            remaining = firstWord(after).rest
            continue
        }
        if option.contains("=") {
            remaining = after
            continue
        }
        if option.hasPrefix("-") {
            remaining = after
            continue
        }
        break
    }
    return remaining.isEmpty ? nil : remaining
}

func stripCommandWrapper(_ text: String) -> String? {
    let (word, rest) = firstWord(text)
    guard basename(word) == "command" else { return nil }
    let (option, after) = firstWord(rest)
    if option == "-v" || option == "-V" {
        return nil
    }
    if option.hasPrefix("-") {
        return after.isEmpty ? nil : after
    }
    return rest.isEmpty ? nil : rest
}

func stripLeadingBackslash(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\\") else { return nil }
    let rest = String(trimmed.dropFirst())
    let (word, _) = firstWord(rest)
    guard !word.isEmpty,
          word.unicodeScalars.allSatisfy({
              $0.properties.isAlphabetic || ("0"..."9").contains(Character($0))
                  || $0 == "_" || $0 == "-" || $0 == "."
          })
    else {
        return nil
    }
    return rest
}

func stripAbsolutePathOnArgv0(_ text: String) -> String {
    let (word, rest) = firstWord(text)
    guard looksLikeAbsoluteExecutable(word) else { return text }
    let base = basename(word)
    return rest.isEmpty ? base : "\(base) \(rest)"
}

// Internal: the invocation-prefix recorder (NormalizeInvocation) must apply
// the exact argv0-strip condition the view applies.
func looksLikeAbsoluteExecutable(_ word: String) -> Bool {
    guard word.contains("/") else { return false }
    if isRedirectToken(word) { return false }
    return word.hasPrefix("/") || word.hasPrefix("./") || word.hasPrefix("../")
}

private func isRedirectToken(_ word: String) -> Bool {
    if word.hasPrefix(">") || word.hasPrefix("<") || word.hasPrefix("&>") || word.hasPrefix(">&")
        || word.hasPrefix(":>")
    {
        return true
    }
    var index = word.startIndex
    while index < word.endIndex, word[index].isNumber {
        index = word.index(after: index)
    }
    return index > word.startIndex && index < word.endIndex && word[index] == ">"
}

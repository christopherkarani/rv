import Foundation

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
    }
    return remaining.isEmpty ? nil : remaining
}

func stripEnv(_ text: String) -> String? {
    let (word, rest) = firstWord(text)
    guard basename(word) == "env" else { return nil }
    var remaining = rest
    while !remaining.isEmpty {
        let (option, after) = firstWord(remaining)
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

private func looksLikeAbsoluteExecutable(_ word: String) -> Bool {
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

import Foundation

/// Every package name a runner word may name, whatever the spec shape, so
/// a caller tests each against its table. The word is percent-decoded
/// (`@openai%2fcodex`); an option's value (`--package=X`, `-p=X`), an npm
/// alias target (`foo@npm:X`, `foo@jsr:X`) and a nix flake attribute or git
/// ref after `#` (`nixpkgs#claude-code`) are specs of their own. Each spec
/// drops a registry or protocol prefix (`npm:`, `github:`, `https://`), a
/// `#ref`/`?query`, `[extras]` and a `.tgz`/`.tar.gz`/`.tar`/`.git`
/// suffix, then yields every path component and every adjacent pair of
/// them (`@smithery/cli`, `smithery-ai/cli`, `…/install-mcp/dist/index.js`),
/// each without an `@version` or an `npm pack` version (`cli-1.2.3`).
/// Over-reports on purpose: only the names a caller lists count.
func packageNames(_ word: String) -> Set<String> {
    var specs = [word, percentDecoded(word)]
    for spec in specs where spec.hasPrefix("-") {
        if let equals = spec.firstIndex(of: "=") { specs.append(String(spec[spec.index(after: equals)...])) }
    }
    for spec in specs {
        for marker in ["@npm:", "@jsr:"] {
            if let alias = spec.range(of: marker, options: .backwards) { specs.append(String(spec[alias.upperBound...])) }
        }
    }
    for spec in specs {
        if let hash = spec.firstIndex(of: "#") { specs.append(String(spec[spec.index(after: hash)...])) }
    }
    var names: Set<String> = []
    for spec in specs {
        names.formUnion(componentNames(spec))
        let plain = withoutExtras(spec)
        if plain != spec { names.formUnion(componentNames(plain)) }
    }
    names.remove("")
    return names
}

private func componentNames(_ text: String) -> [String] {
    var spec = Substring(text)
    if let scheme = spec.range(of: "://") {
        spec = spec[scheme.upperBound...]
    } else if let colon = spec.firstIndex(of: ":"), colon != spec.startIndex,
              spec[..<colon].allSatisfy({ $0.isLetter || $0 == "+" })
    {
        spec = spec[spec.index(after: colon)...]
    }
    if let cut = spec.firstIndex(where: { $0 == "#" || $0 == "?" }) { spec = spec[..<cut] }
    for suffix in [".tgz", ".tar.gz", ".tar", ".git"] where spec.hasSuffix(suffix) {
        spec = spec.dropLast(suffix.count)
        break
    }
    let parts = spec.split(separator: "/").map(String.init)
    var names = parts.map(unversioned)
    for index in parts.indices.dropFirst() {
        names.append(parts[index - 1] + "/" + unversioned(parts[index]))
        names.append(unversioned(parts[index - 1]) + "/" + unversioned(parts[index]))
    }
    return names
}

/// `name@1.2` → `name`, `cli-1.2.3` → `cli`. A leading `@` is a scope.
private func unversioned(_ part: String) -> String {
    var name = part
    if let at = name.lastIndex(of: "@"), at != name.startIndex { name = String(name[..<at]) }
    let chars = Array(name)
    if let dash = chars.indices.dropLast().first(where: { chars[$0] == "-" && chars[$0 + 1].isNumber }) {
        name = String(chars[..<dash])
    }
    return name
}

/// `mcp[cli]@1.6` → `mcp@1.6`.
private func withoutExtras(_ spec: String) -> String {
    var out = ""
    var depth = 0
    for char in spec {
        if char == "[" {
            depth += 1
        } else if char == "]", depth > 0 {
            depth -= 1
        } else if depth == 0 {
            out.append(char)
        }
    }
    return out
}

/// `%XX` sequences decoded as UTF-8; anything else kept as written.
func percentDecoded(_ text: String) -> String {
    guard text.contains("%") else { return text }
    var bytes: [UInt8] = []
    let utf8 = Array(text.utf8)
    var index = 0
    while index < utf8.count {
        if utf8[index] == UInt8(ascii: "%"), index + 2 < utf8.count,
           let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2])
        {
            bytes.append(high << 4 | low)
            index += 3
        } else {
            bytes.append(utf8[index])
            index += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
}

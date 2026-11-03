import RVDomain

/// `perl -i[ext]` rewrites its file operands in place (`-pi`, `-i.bak -pe`,
/// `-i -ne`). Operands are every word after the switches, less the script
/// file when no `-e`/`-E` program was given. Without `-i` perl only reads
/// them: nil. Parses raw argv; the matching view masks `-e` programs, so
/// the unwrap peel (not the view-based filesystem parse) calls this.
func parsePerl(_ argv: Argv) -> ParsedFilesystemCommand? {
    let words = stripWriterRedirectWords(argv.args)
    let scan = perlSwitchScan(words)
    guard scan.inPlace, scan.files.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .overwrite,
        paths: scan.files + writerRedirectDests(argv),
        recursive: false,
        force: false,
        mode: nil
    )
}

struct PerlSwitchScan {
    var inPlace = false
    var programGiven = false
    var files: [String] = []
}

/// Walks perl's leading switches; the first non-switch word (or the word
/// after `--`) starts the operands.
func perlSwitchScan(_ words: [String]) -> PerlSwitchScan {
    var scan = PerlSwitchScan()
    var index = 0
    while index < words.count {
        let word = words[index]
        index += 1
        if word == "--" { break }
        guard word.hasPrefix("-"), word.count > 1 else {
            index -= 1
            break
        }
        index += consumePerlSwitches(word, next: index < words.count ? words[index] : nil, scan: &scan)
    }
    scan.files = Array(words[min(index, words.count)...])
    if scan.programGiven == false, scan.files.isEmpty == false { scan.files.removeFirst() }
    return scan
}

/// Walks one switch word (`-pi`, `-i.bak`, `-lane`); returns how many
/// following words it took (the value of a trailing `-e`/`-I`).
private func consumePerlSwitches(_ word: String, next: String?, scan: inout PerlSwitchScan) -> Int {
    if word.hasPrefix("--") { return 0 }
    let letters = Array(word.dropFirst())
    var offset = 0
    while offset < letters.count {
        let letter = letters[offset]
        let attached = offset + 1 < letters.count
        switch letter {
        case "i":
            scan.inPlace = true
            return 0
        case "e", "E":
            scan.programGiven = true
            return attached || next == nil ? 0 : 1
        case "l", "0":
            // Optional octal digits only; the cluster continues after them.
            offset += 1
            while offset < letters.count, letters[offset].isNumber { offset += 1 }
        case "I":
            return attached || next == nil ? 0 : 1
        case "C", "M", "m", "F", "d", "D", "x", "V":
            // `-C` (like `-M`) takes only an attached value, never the next word.
            return 0
        default:
            offset += 1
        }
    }
    return 0
}

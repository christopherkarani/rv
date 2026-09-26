func isInterpreterExecutable(_ head: String) -> Bool {
    let folded = head.lowercased()
    return isPythonExecutable(folded)
        || isNodeExecutable(folded)
        || isRubyExecutable(folded)
        || isPerlExecutable(folded)
        || isPHPExecutable(folded)
        || isLuaExecutable(folded)
}

func isPythonExecutable(_ head: String) -> Bool {
    if head == "python" || head == "python2" || head == "python3" {
        return true
    }
    guard head.hasPrefix("python") else { return false }
    return head.dropFirst("python".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isNodeExecutable(_ head: String) -> Bool {
    head == "node" || head == "nodejs"
}

func isRubyExecutable(_ head: String) -> Bool {
    if head == "ruby" { return true }
    guard head.hasPrefix("ruby") else { return false }
    return head.dropFirst("ruby".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isPerlExecutable(_ head: String) -> Bool {
    if head == "perl" { return true }
    guard head.hasPrefix("perl") else { return false }
    return head.dropFirst("perl".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isPHPExecutable(_ head: String) -> Bool {
    if head == "php" { return true }
    guard head.hasPrefix("php") else { return false }
    return head.dropFirst("php".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isLuaExecutable(_ head: String) -> Bool {
    if head == "lua" || head == "luajit" { return true }
    guard head.hasPrefix("lua") else { return false }
    return head.dropFirst("lua".count).allSatisfy { $0.isNumber || $0 == "." }
}

func isInterpreterProgramFlag(command: String?, flag: String) -> Bool {
    guard let command else { return false }
    let folded = command.lowercased()
    if isPythonExecutable(folded) {
        return flag == "-c"
    }
    if isNodeExecutable(folded) {
        return flag == "-e" || flag == "--eval" || flag == "-p" || flag == "--print"
    }
    if isRubyExecutable(folded) || isLuaExecutable(folded) {
        return flag == "-e"
    }
    if isPerlExecutable(folded) {
        if flag == "-e" || flag == "-E" { return true }
        return flag.hasPrefix("-") && flag.hasPrefix("--") == false && flag.contains("e")
    }
    if isPHPExecutable(folded) {
        return flag == "-r"
    }
    return false
}

func maskAttachedInterpreterProgram(command: String?, decoded: String) -> String? {
    guard let command else { return nil }
    let folded = command.lowercased()
    if isRubyExecutable(folded) || isLuaExecutable(folded) || isPerlExecutable(folded),
       decoded.hasPrefix("-e"), decoded.count > 2, decoded.hasPrefix("--") == false
    {
        return "-e "
    }
    if isPerlExecutable(folded), decoded.hasPrefix("-E"), decoded.count > 2 {
        return "-E "
    }
    if isPHPExecutable(folded), decoded.hasPrefix("-r"), decoded.count > 2, decoded.hasPrefix("--") == false {
        return "-r "
    }
    return nil
}

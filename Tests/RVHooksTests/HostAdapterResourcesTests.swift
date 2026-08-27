import Foundation
import RVDomain
import Testing
@testable import RVHooks

@Test(arguments: [HookHost.grok, .pi, .opencode, .openclaw, .hermes])
func hostAdapter_bakedRvPath_roundTripsAllResources(host: HookHost) throws {
    let adapter = try HostAdapterResources.load(for: host)
    let rvPath = "/Applications/rv/bin/rv"
    let rendered = adapter.rendered(rvPath: rvPath)

    #expect(adapter.bakedRvPath(in: rendered) == rvPath)
}

@Test(arguments: [HookHost.grok, .pi, .opencode, .openclaw, .hermes])
func hostAdapter_bakedRvPath_rejectsModifiedAndForeignBytes(host: HookHost) throws {
    let adapter = try HostAdapterResources.load(for: host)
    let rendered = adapter.rendered(rvPath: "/opt/rv/bin/rv")

    #expect(adapter.bakedRvPath(in: rendered + "\nforeign edit") == nil)
    #expect(adapter.bakedRvPath(in: "foreign adapter") == nil)
}

@Test func hostAdapter_matchesCurrent_acceptsAnyBakedPath() throws {
    let adapter = try HostAdapterResources.load(for: .grok)
    let oldPath = adapter.rendered(rvPath: "/old/rv")
    let newPath = adapter.rendered(rvPath: "/new/rv")
    #expect(adapter.matchesCurrent(oldPath))
    #expect(adapter.matchesCurrent(newPath))
    #expect(adapter.matchesCurrent(oldPath + "\nextra") == false)
    #expect(adapter.matchesCurrent("{\"hooks\":[]}\n") == false)
}

@Test func hostAdapter_openClawCompanions_areNonEmptyAndClaudeHasNoTemplate() throws {
    #expect(throws: HostAdapterResourceError.missingTemplate(.claude)) {
        _ = try HostAdapterResources.load(for: .claude)
    }
    let plugin = try HostAdapterResources.loadPluginManifest(for: .openclaw)
    let package = try HostAdapterResources.loadPackageManifest(for: .openclaw)
    #expect(plugin.contains("\"onStartup\": true"))
    #expect(package.contains("\"./index.js\""))
    #expect(throws: HostAdapterResourceError.missingTemplate(.pi)) {
        _ = try HostAdapterResources.loadPluginManifest(for: .pi)
    }
    let hermesPlugin = try HostAdapterResources.loadPluginManifest(for: .hermes)
    #expect(hermesPlugin.contains("provides_hooks:"))
    #expect(hermesPlugin.contains("pre_tool_call"))
    #expect(hermesPlugin.contains("name: rv-guard"))
    #expect(hermesPlugin.contains("\nhooks:") == false)
    let openCodeTui = try HostAdapterResources.loadOpenCodeTuiPlugin()
    #expect(openCodeTui.contains("id: \"rv-guard-tui\""))
    #expect(openCodeTui.contains("server:"))
    #expect(openCodeTui.contains("permission.ask") == false)
    #expect(openCodeTui.contains("DialogConfirm") == false)
    #expect(openCodeTui.contains("dialog.replace") == false)
    #expect(openCodeTui.contains("onConfirm") == false)
    #expect(openCodeTui.contains("onCancel") == false)
    #expect(openCodeTui.contains("registerLayer") == false)
    #expect(openCodeTui.contains("createComponent") == false)
    #expect(openCodeTui.contains("paintOfficialAsk") == false)
    #expect(openCodeTui.contains("RV · Ask") == false)
}

@Test func hostAdapter_piAndOpenCode_matchOnlyTheirOwnRender() throws {
    let pi = try HostAdapterResources.load(for: .pi)
    let openCode = try HostAdapterResources.load(for: .opencode)
    let piBody = pi.rendered(rvPath: "/opt/rv")
    #expect(pi.matchesCurrent(piBody))
    #expect(openCode.matchesCurrent(piBody) == false)
    #expect(pi.matchesCurrent(openCode.rendered(rvPath: "/opt/rv")) == false)
}

@Test func hostAdapter_quotedPath_grokJSONIsValidAndBakesOriginalPath() throws {
    let path = #"/tmp/rv-"bin"/rv"#
    let adapter = try HostAdapterResources.load(for: .grok)
    let body = adapter.rendered(rvPath: path)
    let json = try JSONSerialization.jsonObject(with: Data(body.utf8))
    let command = try grokHookCommand(json)
    #expect(command == path + " hook --host grok")
    #expect(adapter.matchesCurrent(body))
    #expect(adapter.bakedRvPath(in: body) == path)
}

@Test func hostAdapter_quotedPath_piAndOpenCodeBakeOriginalPath() throws {
    let path = #"/tmp/rv-"bin"/rv"#
    for host in [HookHost.pi, .opencode, .openclaw, .hermes] {
        let adapter = try HostAdapterResources.load(for: host)
        let body = adapter.rendered(rvPath: path)
        #expect(adapter.matchesCurrent(body))
        #expect(adapter.bakedRvPath(in: body) == path)
        #expect(binaryLiteral(in: body) == path)
    }
}

@Test(arguments: [HookHost.grok, .pi, .opencode, .openclaw, .hermes])
func hostAdapter_controlAndBackslashPath_roundTrips(host: HookHost) throws {
    let path = "/tmp/rv-\t\"bin\"\\\r/rv"
    let adapter = try HostAdapterResources.load(for: host)
    let body = adapter.rendered(rvPath: path)
    #expect(adapter.bakedRvPath(in: body) == path)
    #expect(adapter.matchesCurrent(body))
    if host == .grok {
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8))
        #expect(try grokHookCommand(json) == path + " hook --host grok")
    } else {
        #expect(binaryLiteral(in: body) == path)
    }
}

private func grokHookCommand(_ json: Any) throws -> String {
    let root = try #require(json as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    let first = try #require(pre.first)
    let inner = try #require(first["hooks"] as? [[String: Any]])
    let command = try #require(inner.first?["command"] as? String)
    return command
}

private func binaryLiteral(in body: String) -> String? {
    let marker = "RV_BINARY = "
    guard let start = body.range(of: marker) else { return nil }
    let rest = body[start.upperBound...]
    guard rest.first == "\"" else { return nil }
    var decoded = ""
    var chars = rest.dropFirst().makeIterator()
    while let ch = chars.next() {
        if ch == "\"" { return decoded }
        if ch == "\\" {
            guard let next = chars.next() else { return nil }
            switch next {
            case "\"": decoded.append("\"")
            case "\\": decoded.append("\\")
            case "n": decoded.append("\n")
            case "r": decoded.append("\r")
            case "t": decoded.append("\t")
            default: return nil
            }
        } else {
            decoded.append(ch)
        }
    }
    return nil
}

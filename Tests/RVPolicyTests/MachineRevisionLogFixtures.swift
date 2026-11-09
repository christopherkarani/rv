import Foundation

/// Golden bytes captured from the pre-refactor `TypedRuleStore` (base 2569eb88)
/// by saving three documents, re-saving the third unchanged, then rolling back
/// to generation 2. They pin the sealed-log wire format (SEC-002): log, tip,
/// key, display JSONL, and live `policy.toml`. The key is a throwaway fixture
/// key, not a secret. Sealed records are r1...r5 (r4 is the identical
/// re-save); public generations are 1...4.
enum MachineRevisionLogFixtures {
    static let keyHex = "8abf292013aa0fc222b992955481c1ec0e4a6bd212140706f185202e7791396b"
    static let sealedRecordCount = 5
    static let generationCount = 4

    /// `policy-revisions.log`, newline-terminated.
    static let log: String = logBody + "\n"
    /// `.policy-revisions.tip`, no trailing newline.
    static let tip: String = #"""
{"mac":"be7da622a87c03c26db229381af88937867202e7ed1cb0c1e8f99feb214c5e11","revision":5,"tip":"ae575ba93a7b8755025a33534de077b86a874ba7116cc0acf62598ff6323d290"}
"""#
    /// `policy-revisions.jsonl`, newline-terminated.
    static let displayLog: String = displayBody + "\n"
    /// `policy.toml`, newline-terminated.
    static let policyTOML: String = policyBody + "\n"

    static var keyBytes: Data {
        Data(stride(from: 0, to: keyHex.count, by: 2).map { offset in
            let start = keyHex.index(keyHex.startIndex, offsetBy: offset)
            return UInt8(keyHex[start..<keyHex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    private static let logBody = #"""
{"mac":"9338f472284e3ad06ef7412cc48d107b16db83e8505b094763b0053f4473dec8","prev":"genesis","recorded_at_ms":1794264550029,"revision":1,"toml_base64":"c2NoZW1hX3ZlcnNpb24gPSAxCgpbW3J1bGVdXQppZCA9ICJjb3JlLmdpdDp2MSIKdmVyZGljdCA9ICJkZW55IgpwcmVkaWNhdGUgPSAiZ2l0UHVzaCIKZm9yY2UgPSAiZm9yY2UiCmJyYW5jaCA9ICJtYWluIgo="}
{"mac":"c942d98123b33d08187b87e80665ca7d6765a0d5d3df7e692c66b71382ba68b8","prev":"9338f472284e3ad06ef7412cc48d107b16db83e8505b094763b0053f4473dec8","recorded_at_ms":1794264550988,"revision":2,"toml_base64":"c2NoZW1hX3ZlcnNpb24gPSAxCgpbW3J1bGVdXQppZCA9ICJjb3JlLmdpdDp2MSIKdmVyZGljdCA9ICJkZW55IgpwcmVkaWNhdGUgPSAiZ2l0UHVzaCIKZm9yY2UgPSAiZm9yY2UiCmJyYW5jaCA9ICJtYWluIgoKW1tydWxlXV0KaWQgPSAiY29yZS5naXQ6djIiCnZlcmRpY3QgPSAiZGVueSIKcHJlZGljYXRlID0gImdpdFB1c2giCmZvcmNlID0gImZvcmNlIgpicmFuY2ggPSAiZGV2ZWxvcCIK"}
{"mac":"bac679248bbc3c4dc058ce9e9ef60f404626fb05b1093f495ba59dac254be262","prev":"c942d98123b33d08187b87e80665ca7d6765a0d5d3df7e692c66b71382ba68b8","recorded_at_ms":1794264551369,"revision":3,"toml_base64":"c2NoZW1hX3ZlcnNpb24gPSAxCgpbW3J1bGVdXQppZCA9ICJjb3JlLmdpdDp2MSIKdmVyZGljdCA9ICJkZW55IgpwcmVkaWNhdGUgPSAiZ2l0UHVzaCIKZm9yY2UgPSAiZm9yY2UiCmJyYW5jaCA9ICJtYWluIgoKW1tydWxlXV0KaWQgPSAiY29yZS5naXQ6djIiCnZlcmRpY3QgPSAiZGVueSIKcHJlZGljYXRlID0gImdpdFB1c2giCmZvcmNlID0gImZvcmNlIgpicmFuY2ggPSAiZGV2ZWxvcCIKCltbcnVsZV1dCmlkID0gInR5cGVkLmdpdDpkaXNjYXJkLWFsbG93Igp2ZXJkaWN0ID0gImFsbG93IgpwcmVkaWNhdGUgPSAiZ2l0RGlzY2FyZFdvcmt0cmVlIgo="}
{"mac":"09042ed1b3b2438c5d9b765db566d7eb371e564e0f711b037766ee6b1580c94d","prev":"bac679248bbc3c4dc058ce9e9ef60f404626fb05b1093f495ba59dac254be262","recorded_at_ms":1794264552066,"revision":4,"toml_base64":"c2NoZW1hX3ZlcnNpb24gPSAxCgpbW3J1bGVdXQppZCA9ICJjb3JlLmdpdDp2MSIKdmVyZGljdCA9ICJkZW55IgpwcmVkaWNhdGUgPSAiZ2l0UHVzaCIKZm9yY2UgPSAiZm9yY2UiCmJyYW5jaCA9ICJtYWluIgoKW1tydWxlXV0KaWQgPSAiY29yZS5naXQ6djIiCnZlcmRpY3QgPSAiZGVueSIKcHJlZGljYXRlID0gImdpdFB1c2giCmZvcmNlID0gImZvcmNlIgpicmFuY2ggPSAiZGV2ZWxvcCIKCltbcnVsZV1dCmlkID0gInR5cGVkLmdpdDpkaXNjYXJkLWFsbG93Igp2ZXJkaWN0ID0gImFsbG93IgpwcmVkaWNhdGUgPSAiZ2l0RGlzY2FyZFdvcmt0cmVlIgo="}
{"mac":"ae575ba93a7b8755025a33534de077b86a874ba7116cc0acf62598ff6323d290","prev":"09042ed1b3b2438c5d9b765db566d7eb371e564e0f711b037766ee6b1580c94d","recorded_at_ms":1794264552390,"revision":5,"toml_base64":"c2NoZW1hX3ZlcnNpb24gPSAxCgpbW3J1bGVdXQppZCA9ICJjb3JlLmdpdDp2MSIKdmVyZGljdCA9ICJkZW55IgpwcmVkaWNhdGUgPSAiZ2l0UHVzaCIKZm9yY2UgPSAiZm9yY2UiCmJyYW5jaCA9ICJtYWluIgoKW1tydWxlXV0KaWQgPSAiY29yZS5naXQ6djIiCnZlcmRpY3QgPSAiZGVueSIKcHJlZGljYXRlID0gImdpdFB1c2giCmZvcmNlID0gImZvcmNlIgpicmFuY2ggPSAiZGV2ZWxvcCIK"}
"""#
    private static let displayBody = #"""
{"schema_version":1,"rule_count":1,"revision":1,"recorded_at":815957350.029,"hash":"d528c3625aa84b8b8e9403c62567973e490c2e87b5f6709548d29e607b6c2737","toml":"schema_version = 1\n\n[[rule]]\nid = \"core.git:v1\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nforce = \"force\"\nbranch = \"main\"\n"}
{"hash":"2756cf4f6805c39a7b4e97871f7dae16582379e7e91f87b1ca6fca80171e30ef","schema_version":1,"toml":"schema_version = 1\n\n[[rule]]\nid = \"core.git:v1\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nforce = \"force\"\nbranch = \"main\"\n\n[[rule]]\nid = \"core.git:v2\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nforce = \"force\"\nbranch = \"develop\"\n","revision":2,"rule_count":2,"recorded_at":815957350.9879999}
{"hash":"53bb77b4194fa21dd23f7b0518c8f109b7a4948c8d7cded35973d829b70e98df","schema_version":1,"toml":"schema_version = 1\n\n[[rule]]\nid = \"core.git:v1\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nforce = \"force\"\nbranch = \"main\"\n\n[[rule]]\nid = \"core.git:v2\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nforce = \"force\"\nbranch = \"develop\"\n\n[[rule]]\nid = \"typed.git:discard-allow\"\nverdict = \"allow\"\npredicate = \"gitDiscardWorktree\"\n","revision":3,"rule_count":3,"recorded_at":815957351.369}
{"hash":"2756cf4f6805c39a7b4e97871f7dae16582379e7e91f87b1ca6fca80171e30ef","schema_version":1,"toml":"schema_version = 1\n\n[[rule]]\nid = \"core.git:v1\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nforce = \"force\"\nbranch = \"main\"\n\n[[rule]]\nid = \"core.git:v2\"\nverdict = \"deny\"\npredicate = \"gitPush\"\nforce = \"force\"\nbranch = \"develop\"\n","revision":4,"rule_count":2,"recorded_at":815957352.3900001}
"""#
    private static let policyBody = #"""
schema_version = 1

[[rule]]
id = "core.git:v1"
verdict = "deny"
predicate = "gitPush"
force = "force"
branch = "main"

[[rule]]
id = "core.git:v2"
verdict = "deny"
predicate = "gitPush"
force = "force"
branch = "develop"
"""#
}

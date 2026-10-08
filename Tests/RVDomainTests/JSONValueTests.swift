import Foundation
import Testing
import RVDomain

@Suite("JSONValue")
struct JSONValueTests {
    @Test func subscripts_readMembersAndNeverTrap() {
        let object = JSONValue.object(["a": .number(1), "n": .null])
        #expect(object["a"] == .number(1))
        #expect(object["missing"] == nil)
        // A present null member is present, not missing.
        #expect(object["n"] == .null)
        #expect(object["n"] != nil)
        #expect(JSONValue.string("x")["a"] == nil)
        #expect(JSONValue.null["a"] == nil)

        let array = JSONValue.array([.string("x"), .bool(true)])
        #expect(array[0] == .string("x"))
        #expect(array[1] == .bool(true))
        #expect(array[2] == nil)
        #expect(array[-1] == nil)
        #expect(JSONValue.object([:])[0] == nil)
    }

    @Test func scalarAccessors_matchOnlyTheirCase() {
        #expect(JSONValue.string("x").string == "x")
        #expect(JSONValue.number(1).string == nil)
        #expect(JSONValue.number(1.5).double == 1.5)
        #expect(JSONValue.string("1.5").double == nil)
        #expect(JSONValue.bool(true).bool == true)
        #expect(JSONValue.number(1).bool == nil)
        #expect(JSONValue.null.isNull)
        #expect(JSONValue.number(0).isNull == false)
        #expect(JSONValue.object(["a": .null]).asObject == ["a": .null])
        #expect(JSONValue.array([]).asObject == nil)
        #expect(JSONValue.array([.null]).asArray == [.null])
        #expect(JSONValue.object([:]).asArray == nil)
    }

    @Test func int_failsClosedWhenLossy() {
        #expect(JSONValue.number(42).int == 42)
        #expect(JSONValue.number(-7).int == -7)
        #expect(JSONValue.number(1.5).int == nil)
        #expect(JSONValue.number(Double.infinity).int == nil)
        #expect(JSONValue.number(Double.nan).int == nil)
        #expect(JSONValue.number(1e300).int == nil)
        #expect(JSONValue.string("42").int == nil)
        #expect(JSONValue.bool(true).int == nil)
        #expect(JSONValue.null.int == nil)
    }

    @Test func decode_readsEveryCase() throws {
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"s":"x","i":42,"f":1.5,"b":true,"n":null,"a":[1,"two"],"o":{"k":false}}"#.utf8)
        )
        #expect(decoded["s"] == .string("x"))
        #expect(decoded["i"] == .number(42))
        #expect(decoded["i"]?.int == 42)
        #expect(decoded["f"] == .number(1.5))
        #expect(decoded["b"] == .bool(true))
        #expect(decoded["n"]?.isNull == true)
        #expect(decoded["a"] == .array([.number(1), .string("two")]))
        #expect(decoded["o"] == .object(["k": .bool(false)]))
    }

    @Test func decode_preservesOutOfDoubleRangeIntegersAsText() throws {
        // 2^53 stays an exact number; 2^64-1 cannot, so it decodes as the
        // digit string instead of a rounded double.
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"exact":9007199254740992,"fallback":18446744073709551615,"negative":-9223372036854775808}"#.utf8)
        )
        #expect(decoded["exact"] == .number(9_007_199_254_740_992))
        #expect(decoded["fallback"] == .string("18446744073709551615"))
        #expect(decoded["negative"] == .number(-9_223_372_036_854_775_808))
        // The fallback is re-encode-stable: text stays text, exact stays exact.
        let roundTripped = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
        #expect(roundTripped == decoded)
    }

    @Test func codable_roundTripsEqual() throws {
        let values: [JSONValue] = [
            .object(["a": .number(1), "b": .array([.string("x"), .null])]),
            .array([.bool(false), .number(-2.5)]),
            .string("héllo"),
            .number(1_710_000_000),
            .bool(true),
            .null,
        ]
        for value in values {
            let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
            #expect(decoded == value)
        }
    }
}

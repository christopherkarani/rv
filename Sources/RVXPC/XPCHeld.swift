#if canImport(XPC)
@preconcurrency import XPC

// Immutable after init. libxpc objects are safe to use from multiple
// threads; the handle itself is never mutated, only passed to xpc calls.
package final class XPCHeld: @unchecked Sendable {
    package let object: xpc_object_t

    package init(_ object: xpc_object_t) {
        self.object = object
    }
}
#endif

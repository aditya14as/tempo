import SwiftUI

/// Drop-in replacement for SwiftUI's `@State`. Use this everywhere you would
/// normally write `@State`.
///
/// Why: starting with the macOS 27 SDK, `@State` resolves to a compiler macro
/// (`SwiftUIMacros.StateMacro`). That macro plugin ships only inside Xcode, not
/// in the free Command Line Tools, so a plain `swift build` on a CLT-only Mac
/// fails with "plugin for module 'SwiftUIMacros' not found". The underlying
/// `State<Value>` property-wrapper struct still exists, and this wrapper simply
/// forwards to it. SwiftUI discovers nested `DynamicProperty` fields by
/// reflection, so this behaves exactly like `@State` (per-view identity,
/// invalidation on change, `$foo` bindings).
///
/// The wrapper needs a distinct name: the compiler prefers the macro over any
/// type called `State`, even one declared in this module.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State<Value>(wrappedValue: wrappedValue)
    }

    init() where Value: ExpressibleByNilLiteral {
        storage = SwiftUI.State<Value>(wrappedValue: nil)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

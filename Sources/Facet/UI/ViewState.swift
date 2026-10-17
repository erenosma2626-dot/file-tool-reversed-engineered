import SwiftUI

/// Drop-in replacement for `@State`.
///
/// Since the macOS 27 SDK, `@State` is a macro whose implementation ships only with the full
/// Xcode app, so it fails to compile with the Command Line Tools alone. This wrapper stores a
/// plain `State` value; SwiftUI discovers it through `DynamicProperty`, so it behaves the same.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

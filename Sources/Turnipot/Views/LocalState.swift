import SwiftUI

/// IMPORTANT: With Command Line Tools only (no Xcode) the SwiftUI macro plugin is missing, so
/// `@State` (a macro in this SDK) and `#Preview` / `@Entry` DO NOT COMPILE.
/// Use `@StateObject private var x = LocalState(initial)` and `x.value` / `$x.value` instead.
/// (@StateObject, @ObservedObject, @FocusState, @GestureState, @Namespace, @Environment,
/// @AppStorage, @Binding and @Observable all work.)
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

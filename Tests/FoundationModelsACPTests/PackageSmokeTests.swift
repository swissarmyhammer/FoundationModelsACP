import Testing

import FoundationModelsACP

/// Smoke test proving the package scaffold compiles and exposes its
/// placeholder public namespace symbol.
@Test func packageExposesACPNamespace() {
    // `ACP` is the placeholder public symbol from the scaffold task; the
    // package compiles and the symbol is referenceable.
    let namespace: ACP.Type = ACP.self
    #expect(namespace == ACP.self)
}

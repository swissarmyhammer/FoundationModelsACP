import Testing

import FoundationModelsACP

/// Verifies the package scaffold exposes its placeholder `ACP` namespace.
@Test func packageExposesACPNamespace() {
    // The placeholder public symbol from the scaffold task must be reachable
    // through the package's public surface under its expected type name.
    #expect(String(describing: ACP.self) == "ACP")
}

import Testing
@testable import Sidecar

@Test func moduleIsNamed() {
    #expect(SidecarModule.name == "Sidecar")
}

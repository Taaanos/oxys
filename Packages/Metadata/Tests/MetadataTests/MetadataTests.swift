import Testing
@testable import Metadata

@Test func moduleIsNamed() {
    #expect(MetadataModule.name == "Metadata")
}

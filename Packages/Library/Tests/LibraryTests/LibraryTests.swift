import Testing
@testable import Library

@Test func moduleIsNamed() {
    #expect(LibraryModule.name == "Library")
}

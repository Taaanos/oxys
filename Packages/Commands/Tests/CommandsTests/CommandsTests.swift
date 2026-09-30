import Testing
@testable import Commands

@Test func moduleIsNamed() {
    #expect(CommandsModule.name == "Commands")
}

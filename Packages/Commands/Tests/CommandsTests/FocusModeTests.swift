import Testing
@testable import Commands

@Test func focusModeOffLeavesEverySavedStateAlone() {
    var focus = FocusMode()
    for panel in Panel.allCases {
        #expect(focus.isVisible(panel, saved: true))
        #expect(!focus.isVisible(panel, saved: false))
        #expect(focus.press(panel, saved: true) == .toggle)
    }
    #expect(focus.revealed.isEmpty)
}

@Test func focusModeHidesEveryPanelWithoutChangingTheSavedLayout() {
    var focus = FocusMode()
    focus.toggle()
    for panel in Panel.allCases { #expect(!focus.isVisible(panel, saved: true)) }
    focus.toggle()
    for panel in Panel.allCases { #expect(focus.isVisible(panel, saved: true)) }
}

@Test func aPanelKeyInFocusModeShowsThatPanelOnly() {
    var focus = FocusMode()
    focus.toggle()
    #expect(focus.press(.histogram, saved: true) == .reveal)
    #expect(focus.isVisible(.histogram, saved: true))
    for panel in Panel.allCases where panel != .histogram { #expect(!focus.isVisible(panel, saved: true)) }
}

@Test func aPanelSavedOffIsTurnedOnWhenAskedForInFocusMode() {
    var focus = FocusMode()
    focus.toggle()
    #expect(focus.press(.filterBar, saved: false) == .turnOnAndReveal)
    #expect(focus.isVisible(.filterBar, saved: true))
}

@Test func theSecondPressOnARevealedPanelToggles() {
    var focus = FocusMode()
    focus.toggle()
    _ = focus.press(.info, saved: true)
    #expect(focus.press(.info, saved: true) == .toggle)
    #expect(!focus.revealed.contains(.info))
    #expect(!focus.isVisible(.info, saved: false))
}

@Test func leavingOrEnteringFocusModeClearsWhatWasRevealed() {
    var focus = FocusMode()
    focus.toggle()
    _ = focus.press(.inspector, saved: true)
    focus.toggle()
    #expect(focus.revealed.isEmpty)
    focus.toggle()
    #expect(!focus.isVisible(.inspector, saved: true))
}

@Test func revealShowsAPanelWithoutTogglingIt() {
    var focus = FocusMode()
    focus.reveal(.filterBar)
    #expect(focus.revealed.isEmpty)
    focus.toggle()
    focus.reveal(.filterBar)
    focus.reveal(.filterBar)
    #expect(focus.isVisible(.filterBar, saved: true))
    #expect(focus.press(.filterBar, saved: true) == .toggle)
}

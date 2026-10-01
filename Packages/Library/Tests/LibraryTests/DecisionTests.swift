import Foundation
import Testing
@testable import Library

@Suite struct DecisionTests {
    @Test func starsSetAndClear() {
        var d = CullAction.setRating(3).applied(to: .none)
        #expect(d.rating == 3)
        d = CullAction.setRating(3).applied(to: d)   // Q3: same count again changes nothing
        #expect(d.rating == 3)
        d = CullAction.setRating(0).applied(to: d)
        #expect(d == .none)
    }

    @Test func rejectToggleGoesBackToZeroNotOldStars() {
        let rejected = CullAction.toggleReject.applied(to: Decision(rating: 3))
        #expect(rejected.isReject)
        #expect(CullAction.toggleReject.applied(to: rejected).rating == 0)   // Q1
    }

    @Test func settingStarsOnARejectUnrejects() {
        #expect(CullAction.setRating(2).applied(to: Decision(rating: -1)).rating == 2)
        #expect(CullAction.setRating(0).applied(to: Decision(rating: -1)).rating == 0)
    }

    @Test func stepsStayWithinZeroToFive() {
        #expect(CullAction.stepRating(1).applied(to: Decision(rating: 5)).rating == 5)
        #expect(CullAction.stepRating(-1).applied(to: Decision(rating: 0)).rating == 0)
        #expect(CullAction.stepRating(1).applied(to: Decision(rating: 2)).rating == 3)
        #expect(CullAction.stepRating(-1).applied(to: Decision(rating: 2)).rating == 1)
    }

    @Test func stepsOnARejectFollowQ4() {
        let reject = Decision(rating: -1)
        #expect(CullAction.stepRating(1).applied(to: reject).rating == 1)
        #expect(CullAction.stepRating(-1).applied(to: reject) == reject)
    }

    @Test func labelKeyTogglesAndKeepsRating() {
        var d = CullAction.toggleLabel(.red).applied(to: Decision(rating: 4))
        #expect(d == Decision(rating: 4, label: .red))
        d = CullAction.toggleLabel(.blue).applied(to: d)
        #expect(d.label == .blue)
        d = CullAction.toggleLabel(.blue).applied(to: d)
        #expect(d == Decision(rating: 4))
    }

    @Test func rejectKeepsTheLabel() {
        let d = CullAction.toggleReject.applied(to: Decision(rating: 2, label: .green))
        #expect(d == Decision(rating: -1, label: .green))
    }

    @Test func summaryIsOnePhrase() {
        #expect(Decision(rating: 3, label: .red).summary == "3 stars, red label")
        #expect(Decision(rating: 1).summary == "1 star")
        #expect(Decision(rating: -1).summary == "Rejected")
        #expect(Decision.none.summary == "No rating")
        #expect(Decision(rating: 0, label: .purple).summary == "purple label")
    }

    @Test func labelsHaveDistinctLetters() {
        #expect(Set(ColorLabel.allCases.map(\.letter)).count == ColorLabel.allCases.count)
    }

    @MainActor @Test func folderAppliesToCurrentAndSurvivesTheCaptureTimeResort() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.jpg", modified: Date(timeIntervalSince1970: 1_000))
        try folder.add("b.jpg", modified: Date(timeIntervalSince1970: 2_000))
        let model = FolderModel()
        model.open(folder.url)
        while model.content != .photos { await Task.yield() }
        let a = try #require(model.photos.first { $0.name == "a.jpg" }).url
        #expect(model.apply(.setRating(4), to: a)?.rating == 4)
        #expect(model.photos.first { $0.url == a }?.decision.rating == 4)
        while model.isReadingCaptureTimes { await Task.yield() }
        #expect(model.photos.first { $0.url == a }?.decision.rating == 4)
        #expect(model.apply(.toggleReject, to: URL(fileURLWithPath: "/nope")) == nil)
    }
}

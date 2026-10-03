import Foundation
import Testing
@testable import Library

@Suite struct PhotoFilterTests {
    private func photo(_ name: String, rating: Int = 0, label: ColorLabel? = nil, at seconds: Double = 0) -> Photo {
        var p = Photo(url: URL(fileURLWithPath: "/tmp/\(name)"), format: .arw, fileSize: 1,
                      modificationDate: Date(timeIntervalSince1970: seconds), captureTime: Date(timeIntervalSince1970: seconds))
        p.decision = Decision(rating: rating, label: label)
        return p
    }

    private var sample: [Photo] {
        [photo("IMG_1.ARW", rating: 3, label: .red, at: 1), photo("IMG_2.ARW", rating: -1, at: 2),
         photo("IMG_10.ARW", rating: 5, label: .blue, at: 3), photo("Other.ARW", rating: 1, label: .red, at: 4)]
    }

    @Test func defaultShowsEverythingInOrder() {
        #expect(PhotoFilter().apply(to: sample).map(\.name) == sample.map(\.name))
    }

    @Test func minimumStarsExcludesRejects() {
        var f = PhotoFilter()
        f.setMinimumStars(3)
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW", "IMG_10.ARW"])
        f.setMinimumStars(0)
        #expect(f.apply(to: sample).count == 4)
    }

    @Test func labelsMatchAnyChosen() {
        var f = PhotoFilter()
        f.labels = [.red, .blue]
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW", "IMG_10.ARW", "Other.ARW"])
        f.labels = [.blue]
        #expect(f.apply(to: sample).map(\.name) == ["IMG_10.ARW"])
    }

    @Test func rejectModes() {
        var f = PhotoFilter()
        f.rejects = .hideRejected
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW", "IMG_10.ARW", "Other.ARW"])
        f.rejects = .onlyRejected
        #expect(f.apply(to: sample).map(\.name) == ["IMG_2.ARW"])
    }

    @Test func criteriaCombine() {
        var f = PhotoFilter()
        f.setMinimumStars(1)
        f.labels = [.red]
        f.rejects = .hideRejected
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW", "Other.ARW"])
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        var f = PhotoFilter()
        f.search = "img_1"
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW", "IMG_10.ARW"])
        f.search = "  "
        #expect(f.apply(to: sample).count == 4)
    }

    @Test func turningItOffKeepsSettings() {
        var f = PhotoFilter()
        f.setMinimumStars(4)
        f.isOn = false
        #expect(f.apply(to: sample).count == 4)
        #expect(f.stars == [4, 5])
        f.isOn = true
        #expect(f.apply(to: sample).count == 1)
    }

    @Test func sortsByNameNumericallyAndDescending() {
        var f = PhotoFilter()
        f.sortKey = .filename
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW", "IMG_2.ARW", "IMG_10.ARW", "Other.ARW"])
        f.ascending = false
        #expect(f.apply(to: sample).map(\.name) == ["Other.ARW", "IMG_10.ARW", "IMG_2.ARW", "IMG_1.ARW"])
        f = PhotoFilter()
        f.ascending = false
        #expect(f.apply(to: sample).map(\.name) == ["Other.ARW", "IMG_10.ARW", "IMG_2.ARW", "IMG_1.ARW"])
    }

    @Test func keptPhotoStaysAfterLeavingTheFilter() {
        var f = PhotoFilter()
        f.setMinimumStars(3)
        let kept = sample[3].url // 1 star: does not match
        #expect(f.apply(to: sample, keeping: kept).map(\.name) == ["IMG_1.ARW", "IMG_10.ARW", "Other.ARW"])
    }

    @Test func starClicks() {
        var f = PhotoFilter()
        f.clickStar(2)
        #expect(f.stars == [2])
        f.clickStar(5, extend: true)
        #expect(f.stars == [2, 3, 4, 5])
        f.clickStar(3, extend: true)
        #expect(f.stars == [2, 3])
        f.clickStar(1, extend: true)
        #expect(f.stars == [1, 2])
        f.clickStar(3, orMore: true)
        #expect(f.stars == [3, 4, 5])
        f.clickStar(4)
        f.clickStar(4)
        #expect(f.stars.isEmpty)
    }

    @Test func commandClickPicksSeparateStars() {
        var f = PhotoFilter()
        f.clickStar(1)
        f.clickStar(3, toggle: true)
        #expect(f.stars == [1, 3])
        #expect(f.summary == "1 and 3 stars")
        f.clickStar(1, toggle: true)
        #expect(f.stars == [3])
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW"])
    }

    @Test func maximumLeavesOutHigherAndRejects() {
        var f = PhotoFilter()
        f.clickStar(1)
        f.clickStar(3, extend: true)
        #expect(f.apply(to: sample).map(\.name) == ["IMG_1.ARW", "Other.ARW"])
        #expect(f.summary == "1 to 3 stars")
    }

    private var withBlanks: [Photo] {
        sample + [photo("Blank.ARW", at: 5), photo("RedOnly.ARW", label: .red, at: 6), photo("StarsOnly.ARW", rating: 2, at: 7)]
    }

    @Test func noStarsShowsOnlyUnratedAndNeverRejects() {
        var f = PhotoFilter()
        f.clickStar(0)
        #expect(f.stars == [0] && f.summary == "no stars")
        #expect(f.apply(to: withBlanks).map(\.name) == ["Blank.ARW", "RedOnly.ARW"])
        f.clickStar(0)
        #expect(f.stars.isEmpty)
    }

    @Test func noStarsCombinesWithOtherStars() {
        var f = PhotoFilter()
        f.clickStar(0)
        f.clickStar(5, toggle: true)
        #expect(f.summary == "no stars and 5 stars")
        #expect(f.apply(to: withBlanks).map(\.name) == ["IMG_10.ARW", "Blank.ARW", "RedOnly.ARW"])
    }

    @Test func noLabelShowsOnlyUnlabeled() {
        var f = PhotoFilter()
        f.noLabel = true
        #expect(f.hasCriteria && f.summary == "no label")
        #expect(f.apply(to: withBlanks).map(\.name) == ["IMG_2.ARW", "Blank.ARW", "StarsOnly.ARW"])
    }

    @Test func noLabelCombinesWithColors() {
        var f = PhotoFilter()
        f.labels = [.blue]; f.noLabel = true
        #expect(f.summary == "blue or no label")
        #expect(f.apply(to: withBlanks).map(\.name) == ["IMG_2.ARW", "IMG_10.ARW", "Blank.ARW", "StarsOnly.ARW"])
    }

    @Test func noStarsAndNoLabelTogether() {
        var f = PhotoFilter()
        f.clickStar(0); f.noLabel = true
        #expect(f.apply(to: withBlanks).map(\.name) == ["Blank.ARW"])
    }

    @Test func aSessionSavedBeforeNoLabelStillLoads() throws {
        let old = #"{"isOn":true,"stars":[3],"labels":["red"],"rejects":"showAll","search":"","sortKey":"captureTime","ascending":true}"#
        let f = try JSONDecoder().decode(PhotoFilter.self, from: Data(old.utf8))
        #expect(f.stars == [3] && f.labels == [.red] && !f.noLabel)
        let again = try JSONDecoder().decode(PhotoFilter.self, from: JSONEncoder().encode(f))
        #expect(again == f)
    }
}

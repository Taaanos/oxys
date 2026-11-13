import Foundation
import Testing
@testable import Library

@Suite @MainActor struct FilterModelTests {
    private func waitUntilLoaded(_ model: FolderModel) async {
        for _ in 0..<500 where model.content != .photos || model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<500 where model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func open(_ folder: TempFolder) async -> FolderModel {
        let model = FolderModel()
        model.open(folder.url)
        await waitUntilLoaded(model)
        return model
    }

    private func threePhotos() async throws -> (TempFolder, FolderModel) {
        let folder = try TempFolder()
        for name in ["a.ARW", "b.ARW", "c.ARW"] { try folder.add(name) }
        let model = await open(folder)
        model.setCurrent(index: 0); model.apply(.setRating(4))
        model.setCurrent(index: 2); model.apply(.setRating(5))
        return (folder, model)
    }

    @Test func filterNarrowsWhatNavigationWalks() async throws {
        let (folder, model) = try await threePhotos(); defer { folder.remove() }
        model.updateFilter { $0.setMinimumStars(4) }
        #expect(model.visible.map(\.name) == ["a.ARW", "c.ARW"])
        #expect(model.photos.count == 3)
        model.setCurrent(index: 0)
        model.move(.next)
        #expect(model.currentPhoto?.name == "c.ARW")
        model.updateFilter { $0.isOn = false }
        #expect(model.visible.count == 3)
        #expect(model.filter.stars == [4, 5])
    }

    @Test func aDecisionKeepsTheCurrentPhotoUntilYouMoveAway() async throws {
        let (folder, model) = try await threePhotos(); defer { folder.remove() }
        model.updateFilter { $0.setMinimumStars(4) }
        model.setCurrent(index: 0)
        model.apply(.setRating(1))
        #expect(model.visible.map(\.name) == ["a.ARW", "c.ARW"])
        model.move(.next)
        #expect(model.visible.map(\.name) == ["c.ARW"])
    }

    @Test func hiddenCurrentMovesToTheNextShownAndSelectionIsTrimmed() async throws {
        let (folder, model) = try await threePhotos(); defer { folder.remove() }
        model.setCurrent(index: 1)
        model.selectAll()
        model.updateFilter { $0.setMinimumStars(4) }
        #expect(model.currentPhoto?.name == "c.ARW")
        #expect(model.selection.count == 2)
    }

    @Test func sortChangesDisplayOrderNotTheCatalog() async throws {
        let (folder, model) = try await threePhotos(); defer { folder.remove() }
        model.updateFilter { $0.ascending = false }
        #expect(model.visible.map(\.name) == ["c.ARW", "b.ARW", "a.ARW"])
        #expect(model.photos.map(\.name) == ["a.ARW", "b.ARW", "c.ARW"])
    }

    @Test func openingNewFolderResetsFilter() async throws {
        let (first, model) = try await threePhotos(); defer { first.remove() }
        let second = try TempFolder(); defer { second.remove() }
        for name in ["x.ARW", "y.ARW"] { try second.add(name) }

        model.updateFilter {
            $0.setMinimumStars(4)
            $0.search = "a."
            $0.sortKey = .filename
            $0.ascending = false
        }
        #expect(model.visible.map(\.name) == ["a.ARW"])

        model.open(second.url)
        await waitUntilLoaded(model)
        #expect(model.filter == PhotoFilter())
        #expect(model.visible.map(\.name) == ["x.ARW", "y.ARW"])
    }
}

import Foundation
import Testing
@testable import Library

@Suite @MainActor struct SelectionTests {
    private func open(_ folder: TempFolder) async -> FolderModel {
        let model = FolderModel()
        model.open(folder.url)
        for _ in 0..<500 where model.content != .photos || model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<500 where model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    /// Five photos a.ARW … e.ARW with ratings 1…5 (e is rejected instead of 5), a and c labelled red.
    private func five(_ folder: TempFolder) async throws -> FolderModel {
        for name in ["a", "b", "c", "d", "e"] { try folder.add("\(name).ARW") }
        let model = await open(folder)
        for (i, photo) in model.photos.enumerated() {
            model.setCurrent(photo.url)
            model.apply(.setRating(i + 1))
        }
        model.setCurrent(model.photos[4].url)
        model.apply(.toggleReject)
        for i in [0, 2] { model.setCurrent(model.photos[i].url); model.apply(.toggleLabel(.red)) }
        model.selectNone()
        return model
    }

    private func names(_ model: FolderModel) -> [String] {
        model.photos.filter { model.selection.contains($0.url) }.map(\.name)
    }

    @Test func selectAllSelectsEveryPhoto() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.selectAll()
        #expect(model.selection.count == 5)
        model.selectNone()
        #expect(model.selection.isEmpty)
    }

    @Test func invertSwapsSelectedAndUnselected() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.click(model.photos[1].url, mode: .replace)
        model.click(model.photos[3].url, mode: .toggle)
        model.invertSelection()
        #expect(names(model) == ["a.ARW", "c.ARW", "e.ARW"])
    }

    @Test func clickModes() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.click(model.photos[1].url, mode: .replace)
        model.click(model.photos[3].url, mode: .range)
        #expect(names(model) == ["b.ARW", "c.ARW", "d.ARW"])
        model.click(model.photos[0].url, mode: .toggle)
        #expect(names(model) == ["a.ARW", "b.ARW", "c.ARW", "d.ARW"])
        model.click(model.photos[0].url, mode: .toggle)
        #expect(names(model) == ["b.ARW", "c.ARW", "d.ARW"])
        #expect(model.currentURL == model.photos[0].url)
    }

    @Test func shiftArrowExtendsFromTheActivePhoto() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.setCurrent(index: 1)
        model.extendSelection(toIndex: 2)
        model.extendSelection(toIndex: 3)
        #expect(names(model) == ["b.ARW", "c.ARW", "d.ARW"])
        model.extendSelection(toIndex: 2)
        #expect(names(model) == ["b.ARW", "c.ARW"])
    }

    @Test func deselectCurrentRemovesOnlyTheActivePhoto() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.selectAll()
        model.setCurrent(index: 2)
        model.deselectCurrent()
        #expect(names(model) == ["a.ARW", "b.ARW", "d.ARW", "e.ARW"])
    }

    @Test func selectByRatingAndLabel() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.select(matching: .init(rating: .atLeast(3)))
        #expect(names(model) == ["c.ARW", "d.ARW"])   // e is rejected, so not "3 or more"
        model.select(matching: .init(rating: .rejected))
        #expect(names(model) == ["e.ARW"])
        model.select(matching: .init(label: .color(.red)))
        #expect(names(model) == ["a.ARW", "c.ARW"])
        model.select(matching: .init(rating: .atLeast(2), label: .color(.red)))
        #expect(names(model) == ["c.ARW"])
        model.select(matching: .init(label: .unlabeled))
        #expect(names(model) == ["b.ARW", "d.ARW", "e.ARW"])
        model.select(matching: .init(rating: .exactly(2)))
        #expect(names(model) == ["b.ARW"])
        model.select(matching: .init(rating: .atMost(2)))
        #expect(names(model) == ["a.ARW", "b.ARW"])   // e is rejected, so not "2 or fewer"
        #expect(SelectionCriteria(rating: .atLeast(3), label: .color(.red)).summary == "3 stars or more, red label")
    }

    @Test func cullTargetsAreTheSelectionOrTheCurrentPhoto() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.setCurrent(index: 3)
        #expect(model.cullTargets == [model.photos[3].url])
        model.click(model.photos[4].url, mode: .replace)
        model.click(model.photos[1].url, mode: .toggle)
        #expect(model.cullTargets == [model.photos[1].url, model.photos[4].url])
    }

    @Test func cullOnTheSelectionIsOneUndoStep() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.select(matching: .init(rating: .atLeast(1)))
        model.apply(.setRating(4), toAll: model.cullTargets)
        #expect(model.photos.prefix(4).allSatisfy { $0.decision.rating == 4 })
        model.undo()
        #expect(model.photos.prefix(4).map(\.decision.rating) == [1, 2, 3, 4])
    }

    @Test func selectionIsClearedWhenAnotherFolderOpens() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = try await five(folder)
        model.selectAll()
        model.open(folder.url)
        #expect(model.selection.isEmpty)
    }

    @Test func retainDropsPhotosThatAreGone() {
        let a = URL(filePath: "/x/a.ARW"), b = URL(filePath: "/x/b.ARW")
        let photo = { (url: URL) in Photo(url: url, format: .arw, fileSize: 1, modificationDate: .now) }
        var selection = Selection()
        selection.selectAll([photo(a), photo(b)])
        selection.retain([photo(b)])
        #expect(selection.urls == [b])
    }
}

import Foundation
import Sidecar
import Testing
@testable import Library

@Suite @MainActor struct UndoTests {
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

    private func props(_ name: String, in folder: TempFolder) throws -> XMPProperties {
        try XMPReader.parse(Data(contentsOf: folder.url.appendingPathComponent(name)))
    }

    private func exists(_ name: String, in folder: TempFolder) -> Bool {
        FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(name).path)
    }

    private func seeded(rating: Int, in folder: TempFolder, name: String = "a.xmp") throws {
        try Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="\#(rating)"/></rdf:RDF></x:xmpmeta>"#.utf8)
            .write(to: folder.url.appendingPathComponent(name))
    }

    @Test func undoRestoresTheRatingInTheModelAndTheSidecar() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try seeded(rating: 2, in: folder)
        let model = await open(folder)
        model.apply(.setRating(3)); model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder).rating == 3)
        #expect(model.undoName == "Set Rating")
        model.undo(); model.flushSidecarWrites()
        #expect(model.photos[0].decision.rating == 2)
        #expect(try props("a.xmp", in: folder).rating == 2)
        #expect(model.redoName == "Set Rating")
        model.redo(); model.flushSidecarWrites()
        #expect(model.photos[0].decision.rating == 3)
        #expect(try props("a.xmp", in: folder).rating == 3)
    }

    @Test func undoingTheDecisionThatCreatedASidecarDeletesIt() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(4)); model.apply(.toggleLabel(.red)); model.flushSidecarWrites()
        #expect(exists("a.xmp", in: folder))
        model.undo(); model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder) == XMPProperties(rating: 4, label: nil))
        model.undo(); model.flushSidecarWrites()
        #expect(!exists("a.xmp", in: folder))
        // The outcome reaches the main actor a moment after the queue finishes.
        for _ in 0..<200 where model.photos[0].sidecar.file != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.photos[0].sidecar.file == nil)
        #expect(model.photos[0].decision == .none)
        model.redo(); model.redo(); model.flushSidecarWrites()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(try props("a.xmp", in: folder) == XMPProperties(rating: 4, label: "Red"))
        #expect(model.photos[0].sidecar.file?.lastPathComponent == "a.xmp")
    }

    @Test func aQuickDoAndUndoLeavesNoFileBehind() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(4)); model.undo(); model.flushSidecarWrites()
        #expect(!exists("a.xmp", in: folder))
    }

    @Test func aSidecarSomeoneElseChangedIsPatchedNotDeleted() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(4)); model.flushSidecarWrites()
        // Another program adds its own settings to the file we created.
        let url = folder.url.appendingPathComponent("a.xmp")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "<rdf:Description ", with: #"<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+1.00" "#)
        try Data(text.utf8).write(to: url)
        model.undo(); model.flushSidecarWrites()
        let out = try String(contentsOf: url, encoding: .utf8)
        #expect(out.contains("crs:Exposure2012"))
        #expect(try props("a.xmp", in: folder).rating == 0)
    }

    @Test func aPreexistingSidecarIsNeverDeletedByUndo() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try seeded(rating: 0, in: folder)
        let model = await open(folder)
        model.apply(.setRating(5)); model.undo(); model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder).rating == 0)
    }

    @Test func undoBringsBackACustomLabelThatAColorReplaced() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2" xmp:Label="Select"/></rdf:RDF></x:xmpmeta>"#.utf8)
            .write(to: folder.url.appendingPathComponent("a.xmp"))
        let model = await open(folder)
        model.apply(.toggleLabel(.red)); model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder).label == "Red")
        model.undo(); model.flushSidecarWrites()
        // The custom label itself cannot be written back from a Decision, but it is kept as it was read.
        #expect(model.photos[0].sidecar.unknownLabel == "Select")
    }

    @Test func undoMovesToThePhotoItChanged() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("b.ARW")
        let model = await open(folder)
        let a = model.photos[0].url, b = model.photos[1].url
        model.apply(.setRating(5), to: a)
        model.move(.next)
        #expect(model.currentURL == b)
        #expect(model.undo() == a)
        #expect(model.currentURL == a)
        model.move(.next)
        #expect(model.redo() == a)
        #expect(model.currentURL == a)
    }

    @Test func aGroupActionIsOneStep() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for name in ["a.ARW", "b.ARW", "c.ARW"] { try folder.add(name) }
        let model = await open(folder)
        model.apply(.toggleReject, toAll: model.photos.map(\.url)); model.flushSidecarWrites()
        #expect(model.photos.allSatisfy { $0.decision.isReject })
        #expect(model.undoStack.undoSteps.count == 1)
        model.undo(); model.flushSidecarWrites()
        #expect(model.photos.allSatisfy { $0.decision == .none })
        #expect(!exists("a.xmp", in: folder) && !exists("b.xmp", in: folder) && !exists("c.xmp", in: folder))
    }

    @Test func aMixedHistoryUndoesAndRedoesInOrder() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("b.ARW")
        let model = await open(folder)
        let a = model.photos[0].url, b = model.photos[1].url
        let actions: [(CullAction, URL)] = [
            (.setRating(3), a), (.toggleLabel(.blue), a), (.toggleReject, b), (.stepRating(1), a), (.toggleReject, b),
            (.toggleLabel(.blue), a), (.setRating(0), a),
        ]
        var snapshots: [[Decision]] = [model.photos.map(\.decision)]
        for (action, url) in actions {
            model.apply(action, to: url)
            snapshots.append(model.photos.map(\.decision))
        }
        let steps = model.undoStack.undoSteps.count
        for i in stride(from: steps - 1, through: 0, by: -1) {
            model.undo()
            #expect(model.photos.map(\.decision) == snapshots[i])
        }
        #expect(model.undoName == nil)
        for i in 1...steps {
            model.redo()
            #expect(model.photos.map(\.decision) == snapshots[i])
        }
        #expect(model.redoName == nil)
        model.flushSidecarWrites()
        for photo in model.photos {
            let name = photo.url.deletingPathExtension().lastPathComponent + ".xmp"
            if photo.decision == .none { continue }
            #expect(try props(name, in: folder).rating == photo.decision.rating)
        }
    }

    @Test func aNewActionEndsTheRedoHistory() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(1)); model.apply(.setRating(2))
        model.undo()
        #expect(model.redoName != nil)
        model.apply(.toggleReject)
        #expect(model.redoName == nil)
        #expect(model.undoName == "Reject")
    }

    @Test func unchangedActionsAreNotUndoSteps() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(0))
        #expect(model.undoName == nil)
    }

    @Test func openingAnotherFolderClearsTheHistory() async throws {
        let one = try TempFolder(); defer { one.remove() }
        let two = try TempFolder(); defer { two.remove() }
        try one.add("a.ARW"); try two.add("b.ARW")
        let model = await open(one)
        model.apply(.setRating(3))
        #expect(model.undoName != nil)
        model.open(two.url)
        #expect(model.undoName == nil)
    }

    @Test func menuNamesDescribeTheAction() {
        let red = Decision(rating: 0, label: .red)
        #expect(CullAction.toggleReject.undoName(from: .none, to: Decision(rating: -1)) == "Reject")
        #expect(CullAction.toggleReject.undoName(from: Decision(rating: -1), to: .none) == "Unreject")
        #expect(CullAction.toggleLabel(.red).undoName(from: .none, to: red) == "Set Label")
        #expect(CullAction.toggleLabel(.red).undoName(from: red, to: .none) == "Clear Label")
        #expect(CullAction.setRating(0).undoName(from: Decision(rating: 3), to: .none) == "Clear Rating")
    }
}

import Darwin
import Foundation
import Synchronization
import Testing
@testable import Sidecar

// MARK: - Deterministic PRNG (SplitMix64)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool(probability num: Int = 1, outOf den: Int = 2) -> Bool {
        Int(next() % UInt64(den)) < num
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Independent XMLDocument Oracle

private let xmpURI = "http://ns.adobe.com/xap/1.0/"
private let rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
private let managedXMPNames: Set<String> = ["Rating", "Label", "MetadataDate"]

private struct XMLOracleResult {
    var properties: XMPProperties
    var metadataDate: String?
    /// Canonical fingerprint of every non-XMP-managed element, attribute, text, comment, and CDATA node.
    var foreignFingerprint: [String]
}

/// Independent DOM oracle built on `Foundation.XMLDocument` (completely separate from `XMPReader` and `XMPPatcher`).
private func inspectWithXMLDocument(_ data: Data) throws -> XMLOracleResult {
    let doc = try XMLDocument(data: data, options: [])
    var props = XMPProperties()
    var metadataDate: String?
    var foreign: [String] = []

    func resolveURI(prefix: String?, on element: XMLElement) -> String? {
        if let prefix, !prefix.isEmpty {
            return element.resolveNamespace(forName: "\(prefix):x")?.stringValue
        }
        var current: XMLElement? = element
        while let el = current {
            if let ns = el.namespace(forPrefix: "")?.stringValue { return ns }
            current = el.parent as? XMLElement
        }
        return nil
    }

    func splitQName(_ qname: String) -> (prefix: String?, local: String) {
        if let colon = qname.firstIndex(of: ":") {
            return (String(qname[..<colon]), String(qname[qname.index(after: colon)...]))
        }
        return (nil, qname)
    }

    func walk(_ node: XMLNode, parentIsRDFDescription: Bool, path: String) {
        switch node.kind {
        case .document:
            for child in node.children ?? [] { walk(child, parentIsRDFDescription: false, path: "") }
        case .element:
            guard let el = node as? XMLElement, let qname = el.name else { return }
            let (prefix, local) = splitQName(qname)
            let uri = resolveURI(prefix: prefix, on: el)
            let isDesc = uri == rdfURI && local == "Description"

            if parentIsRDFDescription, uri == xmpURI, managedXMPNames.contains(local) {
                let value = (el.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                switch local {
                case "Rating": if let n = Int(value) { props.rating = min(max(n, -1), 5) }
                case "Label": props.label = value.isEmpty ? nil : value
                case "MetadataDate": metadataDate = value
                default: break
                }
                return
            }

            let elemKey = "{\(uri ?? "")}\(local)"
            let elemPath = "\(path)/\(elemKey)"

            var foreignAttrs: [String] = []
            for attr in el.attributes ?? [] {
                guard let aq = attr.name else { continue }
                let (ap, al) = splitQName(aq)
                let auri = ap.flatMap { resolveURI(prefix: $0, on: el) }
                let val = attr.stringValue ?? ""
                if isDesc, auri == xmpURI, managedXMPNames.contains(al) {
                    let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch al {
                    case "Rating": if let n = Int(trimmed) { props.rating = min(max(n, -1), 5) }
                    case "Label": props.label = trimmed.isEmpty ? nil : trimmed
                    case "MetadataDate": metadataDate = trimmed
                    default: break
                    }
                } else {
                    foreignAttrs.append("{\(auri ?? "")}\(al)=\(val)")
                }
            }
            foreignAttrs.sort()

            // Collect non-XMP child nodes to know whether a newly synthesized empty rdf:Description should be skipped.
            let children = el.children ?? []
            var childForeign: [String] = []
            let startCount = foreign.count

            // Only emit non-empty foreign descriptions or non-description elements.
            let isOnlyAboutAttr = foreignAttrs.isEmpty || foreignAttrs == ["{\(rdfURI)}about="]
            if !isDesc {
                foreign.append("E:\(elemPath)|\(foreignAttrs.joined(separator: ","))")
            }

            for child in children {
                walk(child, parentIsRDFDescription: isDesc, path: elemPath)
            }

            if isDesc {
                childForeign = Array(foreign[startCount...])
                if !isOnlyAboutAttr || !childForeign.isEmpty {
                    foreign.insert("D:\(elemPath)|\(foreignAttrs.joined(separator: ","))", at: startCount)
                }
            }

        case .text:
            let text = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { foreign.append("T:\(path)=\(text)") }
        case .comment:
            foreign.append("C:\(path)=\(node.stringValue ?? "")")
        case .processingInstruction:
            if let name = node.name {
                foreign.append("PI:\(name)=\(node.stringValue ?? "")")
            }
        default:
            break
        }
    }

    walk(doc, parentIsRDFDescription: false, path: "")
    return XMLOracleResult(properties: props, metadataDate: metadataDate, foreignFingerprint: foreign)
}

// MARK: - Randomized XMP Generator

private func generateRandomXMP(rng: inout SeededRNG) -> Data {
    var out = ""
    let useXPacket = rng.bool(probability: 3, outOf: 4)
    let useCRLF = rng.bool(probability: 1, outOf: 3)
    let nl = useCRLF ? "\r\n" : "\n"

    if useXPacket {
        out += "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\(nl)"
    }
    if rng.bool(probability: 1, outOf: 3) {
        out += "<!-- foreign header comment \(rng.int(in: 1...999)) -->\(nl)"
    }

    let wrapXmpMeta = rng.bool(probability: 4, outOf: 5)
    if wrapXmpMeta {
        out += "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\(nl)"
    }

    // Choose where the XMP namespace is declared (or not at all, or colliding prefix).
    enum XMPDeclMode { case onRDF, onDescription, none, collidingPrefix }
    let declMode = rng.pick([XMPDeclMode.onRDF, .onDescription, .none, .collidingPrefix])
    let xmpPrefix = rng.pick(["xmp", "xap", "m"])

    var rdfAttrs = "xmlns:rdf=\"\(rdfURI)\""
    if declMode == .onRDF {
        rdfAttrs += " xmlns:\(xmpPrefix)=\"\(xmpURI)\""
    }
    out += " <rdf:RDF \(rdfAttrs)>\(nl)"

    let descCount = rng.int(in: 0...3)
    for d in 0..<descCount {
        var attrs: [String] = ["rdf:about=\"\""]
        let hasLocalXMP = (declMode == .onDescription && (d == 0 || rng.bool()))
        let hasXMPInScope = (declMode == .onRDF) || hasLocalXMP
        if hasLocalXMP {
            attrs.append("xmlns:\(xmpPrefix)=\"\(xmpURI)\"")
        } else if declMode == .collidingPrefix && d == 0 {
            attrs.append("xmlns:xmp=\"http://example.com/not-xmp/\"")
            attrs.append("xmp:Rating=\"999\"") // Foreign namespace: must never be touched!
        }

        // Foreign namespaces & attributes
        let includeCRS = rng.bool(probability: 2, outOf: 3)
        if includeCRS {
            attrs.append("xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"")
            let exp = String(format: "%+.2f", Double(rng.int(in: -300...300)) / 100.0)
            attrs.append("crs:Exposure2012=\"\(exp)\"")
            attrs.append("crs:Note=\"A &amp; B &lt;C&gt; &quot;D&quot;\"")
        }

        // Optionally place initial XMP properties as attributes (using double quotes; single quotes tested separately).
        if hasXMPInScope && rng.bool(probability: 1, outOf: 2) {
            if rng.bool() {
                attrs.append("\(xmpPrefix):Rating=\"\(rng.int(in: -1...5))\"")
            }
            if rng.bool() {
                let lbl = rng.pick(["Red", "Yellow", "Green", "Blue", "Purple", "Select", "Custom &amp; Label"])
                attrs.append("\(xmpPrefix):Label=\"\(lbl)\"")
            }
            if rng.bool() {
                attrs.append("\(xmpPrefix):MetadataDate=\"2025-01-01T00:00:00+00:00\"")
            }
        }

        var children: [String] = []
        // Optionally place XMP properties as child elements (paired or self-closing).
        if hasXMPInScope && rng.bool(probability: 1, outOf: 2) {
            if rng.bool() {
                children.append("   <\(xmpPrefix):Rating>\(rng.int(in: -1...5))</\(xmpPrefix):Rating>")
            }
            if rng.bool() {
                if rng.bool(probability: 1, outOf: 3) {
                    children.append("   <\(xmpPrefix):Label/>")
                } else {
                    let lbl = rng.pick(["Red", "Blue", "Review"])
                    children.append("   <\(xmpPrefix):Label>\(lbl)</\(xmpPrefix):Label>")
                }
            }
        }

        // Foreign nested subtrees (dc:subject, crs:ToneCurve, comments, CDATA)
        if rng.bool(probability: 2, outOf: 3) {
            children.append("   <dc:subject xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><rdf:Bag><rdf:li>tag_\(d)_\(rng.int(in: 1...99))</rdf:li></rdf:Bag></dc:subject>")
        }
        if rng.bool(probability: 1, outOf: 3) {
            children.append("   <!-- keep me \(d) -->")
        }
        if rng.bool(probability: 1, outOf: 4) {
            children.append("   <ext:Raw xmlns:ext=\"http://example.com/ext/\"><![CDATA[raw <xmp:Rating>1</xmp:Rating> text]]></ext:Raw>")
        }

        if children.isEmpty {
            out += "  <rdf:Description \(attrs.joined(separator: " "))/>\(nl)"
        } else {
            out += "  <rdf:Description \(attrs.joined(separator: " "))>\(nl)"
            for c in children { out += "\(c)\(nl)" }
            out += "  </rdf:Description>\(nl)"
        }
    }

    out += " </rdf:RDF>\(nl)"
    if wrapXmpMeta {
        out += "</x:xmpmeta>\(nl)"
    }
    if useXPacket {
        if rng.bool(probability: 1, outOf: 3) {
            out += String(repeating: " ", count: rng.int(in: 10...80)) + nl
        }
        out += "<?xpacket end=\"w\"?>\(nl)"
    }
    return Data(out.utf8)
}

private func randomEdit(rng: inout SeededRNG) -> SidecarEdit {
    let rating = rng.int(in: -2...7) // Intentionally outside [-1, 5] to verify clamping.
    let label: SidecarEdit.LabelChange = switch rng.int(in: 0...4) {
    case 0: .keep
    case 1: .remove
    case 2: .set(rng.pick(["Red", "Yellow", "Green", "Blue", "Purple"]))
    case 3: .set(rng.pick(["Select", "Second", "Approved", "Client Pick"]))
    default: .set("A & B <\"C\">")
    }
    return SidecarEdit(rating: rating, label: label)
}

// MARK: - Suite 1: Differential & Mutation Tests for XMPPatcher + XMPReader

@Suite struct XMPDifferentialTests {
    @Test(arguments: [UInt64(0x1001), 0x2002, 0x3003, 0x4004, 0x5005, 0x6006])
    func patchAndReadMatchXMLDocumentOracle(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        for docIndex in 0..<25 {
            var current = generateRandomXMP(rng: &rng)
            let initialOracle = try inspectWithXMLDocument(current)
            let initialRead = try XMPReader.parse(current)
            #expect(initialRead == initialOracle.properties,
                    "seed=\(hex(seed)) doc=\(docIndex): initial XMPReader vs XMLDocument mismatch")

            var expectedLabel = initialOracle.properties.label

            for step in 0..<10 {
                let edit = randomEdit(rng: &rng)
                let date = baseDate.addingTimeInterval(Double(docIndex * 100 + step))
                let patched = try XMPPatcher.patch(current, edit: edit, date: date)

                // 1. Must parse cleanly in independent XMLDocument oracle AND in XMPReader.
                let oracle = try inspectWithXMLDocument(patched)
                let parsed = try XMPReader.parse(patched)

                // 2. Expected state after this edit.
                switch edit.label {
                case .keep: break
                case .remove: expectedLabel = nil
                case .set(let s): expectedLabel = s
                }
                let expectedProps = XMPProperties(rating: edit.rating, label: expectedLabel)

                #expect(parsed == expectedProps,
                        "seed=\(hex(seed)) doc=\(docIndex) step=\(step): XMPReader=\(parsed) expected=\(expectedProps)")
                #expect(oracle.properties == expectedProps,
                        "seed=\(hex(seed)) doc=\(docIndex) step=\(step): XMLDocument=\(oracle.properties) expected=\(expectedProps)")
                #expect(oracle.metadataDate == XMPPatcher.metadataDate(date),
                        "seed=\(hex(seed)) doc=\(docIndex) step=\(step): MetadataDate mismatch")

                // 3. Zero foreign data loss compared to the original document.
                #expect(oracle.foreignFingerprint == initialOracle.foreignFingerprint,
                        "seed=\(hex(seed)) doc=\(docIndex) step=\(step): foreign XML changed")

                // 4. Idempotence: patching again with identical edit + date produces identical bytes.
                let repatched = try XMPPatcher.patch(patched, edit: edit, date: date)
                #expect(repatched == patched,
                        "seed=\(hex(seed)) doc=\(docIndex) step=\(step): patch not idempotent")

                current = patched
            }
        }
    }

    @Test(arguments: [UInt64(0xA11CE), 0xB0B0, 0xCAFE, 0xDEAD])
    func mutatedAndCorruptXMPNeverCrashesOrCorrupts(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        for i in 0..<250 {
            var bytes = [UInt8](generateRandomXMP(rng: &rng))
            let edit = randomEdit(rng: &rng)

            switch rng.int(in: 0...6) {
            case 0: // Random truncation
                let cut = rng.int(in: 0...max(0, bytes.count - 1))
                bytes = Array(bytes.prefix(cut))
            case 1: // Random byte flips
                let flips = rng.int(in: 1...8)
                for _ in 0..<flips where !bytes.isEmpty {
                    let pos = rng.int(in: 0...(bytes.count - 1))
                    bytes[pos] = UInt8(rng.int(in: 0...255))
                }
            case 2: // Inject null bytes / UTF-16 lookalike
                if !bytes.isEmpty {
                    let pos = rng.int(in: 0...min(500, bytes.count - 1))
                    bytes.insert(0, at: pos)
                }
            case 3: // Inject DOCTYPE
                bytes = Array("<!DOCTYPE xmp [<!ENTITY a \"b\">]>".utf8) + bytes
            case 4: // Unclosed tag / unbalanced close tag
                bytes += Array("</rdf:Description>".utf8)
            case 5: // Drop closing quote
                if let quotePos = bytes.firstIndex(of: 0x22) { bytes.remove(at: quotePos) }
            default: // Pure random bytes
                let len = rng.int(in: 0...256)
                bytes = (0..<len).map { _ in UInt8(rng.int(in: 0...255)) }
            }

            let data = Data(bytes)
            // Neither parser nor patcher may ever crash or trap.
            let parsedBefore = try? XMPReader.parse(data)
            let patched = try? XMPPatcher.patch(data, edit: edit, date: when)

            // Whenever both reader and patcher accept a document (the SidecarWriter contract),
            // the patched output must still parse cleanly and carry the requested edit.
            if let before = parsedBefore, let out = patched {
                let after = try? XMPReader.parse(out)
                #expect(after != nil, "seed=\(hex(seed)) case=\(i): patcher produced unparseable output")
                if let after {
                    #expect(after.rating == edit.rating, "seed=\(hex(seed)) case=\(i): rating lost after patch")
                    switch edit.label {
                    case .set(let s): #expect(after.label == s, "seed=\(hex(seed)) case=\(i): label mismatch")
                    case .remove: #expect(after.label == nil, "seed=\(hex(seed)) case=\(i): label not removed")
                    case .keep: #expect(after.label == before.label, "seed=\(hex(seed)) case=\(i): kept label changed")
                    }
                }
            }
        }
    }
}

// MARK: - Suite 2: Seeded Real-FS Fault Injection + Invariants for SidecarWriteQueue

@Suite struct SidecarFaultInjectionTests {
    private enum FileFault: Equatable {
        case none
        case symlink(target: URL, sentinel: Data)
        case fifo
        case corrupt(Data)
    }

    private struct PhotoTracker {
        let sidecarURL: URL
        var expectedRating: Int?
        var expectedLabel: String?
        var foreignExposure: String?
        var fileExistsOnDisk = false
        var createdAndUntouchedByOutside = false
        var fault: FileFault = .none
        var expectUnsaved = false
        /// The decision still pending in memory while a fault blocked saving.
        var unsavedEdit: SidecarEdit?
        var unsavedRemoveIfCreated = false
    }

    private func makeOutsideXMP(exposure: String, rating: Int, label: String?) -> Data {
        let labelAttr = label.map { " xmp:Label=\"\($0)\"" } ?? ""
        let text = """
            <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="\(rdfURI)">
              <rdf:Description rdf:about="" xmlns:xmp="\(xmpURI)" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="\(exposure)" xmp:Rating="\(rating)"\(labelAttr)/>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>

            """
        return Data(text.utf8)
    }

    private func atomicReplace(_ url: URL, with data: Data, in folder: URL) throws {
        let temp = folder.appendingPathComponent(".outside-\(UUID().uuidString.prefix(8))")
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @Test(arguments: [UInt64(0xF001), 0xF002, 0xF003, 0xF004])
    func seededFaultInjectionPreservesInvariants(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("oxys-dst-sidecar-\(hex(seed))-\(UUID().uuidString)")
        let sentinelDir = fm.temporaryDirectory.appendingPathComponent("oxys-dst-sentinel-\(hex(seed))-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sentinelDir, withIntermediateDirectories: true)
        defer {
            _ = chmod(dir.path, 0o755)
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: sentinelDir)
        }

        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let outcomes = Mutex<[SidecarWriteOutcome]>([])
        let queue = SidecarWriteQueue(
            now: { clock.withLock { $0 = $0.addingTimeInterval(1); return $0 } },
            onOutcome: { outcome in outcomes.withLock { $0.append(outcome) } }
        )

        let photoCount = 6
        var trackers = (0..<photoCount).map { i in
            PhotoTracker(sidecarURL: dir.appendingPathComponent("IMG_\(i).xmp"))
        }

        for round in 0..<40 {
            let idx = rng.int(in: 0...(photoCount - 1))
            let op = rng.int(in: 0...9)

            switch op {
            case 0...3:
                // Burst of 1..4 rapid state-based decisions on the same photo (exercises coalescing).
                // SidecarWriteQueue coalesces pending jobs last-writer-wins: matches FolderModel's contract
                // where `.keep` is only emitted when no label change happened in the burst.
                let burst = rng.int(in: 1...4)
                let keepLabel = rng.bool(probability: 1, outOf: 4)
                var lastEdit = SidecarEdit(rating: 0, label: .keep)
                for _ in 0..<burst {
                    if keepLabel {
                        lastEdit = SidecarEdit(rating: rng.int(in: -2...7), label: .keep)
                    } else {
                        let lbl: SidecarEdit.LabelChange = switch rng.int(in: 0...3) {
                        case 0: .remove
                        case 1: .set(rng.pick(["Red", "Yellow", "Green", "Blue", "Purple"]))
                        case 2: .set(rng.pick(["Select", "Second", "Approved"]))
                        default: .set("A & B <\"C\">")
                        }
                        lastEdit = SidecarEdit(rating: rng.int(in: -2...7), label: lbl)
                    }
                    queue.submit(lastEdit, to: SidecarTarget(primary: trackers[idx].sidecarURL))
                }
                queue.flush()

                if trackers[idx].fault == .none {
                    trackers[idx].expectedRating = lastEdit.rating
                    switch lastEdit.label {
                    case .keep: break
                    case .remove: trackers[idx].expectedLabel = nil
                    case .set(let s): trackers[idx].expectedLabel = s
                    }
                    if !trackers[idx].fileExistsOnDisk {
                        trackers[idx].fileExistsOnDisk = true
                        trackers[idx].createdAndUntouchedByOutside = true
                    }
                    trackers[idx].expectUnsaved = false
                    trackers[idx].unsavedEdit = nil
                    // Immediately after our write, isOwnWrite must recognize it as our own echo.
                    #expect(queue.isOwnWrite(trackers[idx].sidecarURL),
                            "seed=\(hex(seed)) round=\(round) photo=\(idx): expected isOwnWrite == true")
                } else {
                    trackers[idx].expectUnsaved = true
                    trackers[idx].unsavedEdit = lastEdit
                    trackers[idx].unsavedRemoveIfCreated = false
                }

            case 4:
                // Undo to undecided (`removeIfCreatedByUs: true`).
                let edit = SidecarEdit(rating: 0, label: .remove)
                queue.submit(edit, to: SidecarTarget(primary: trackers[idx].sidecarURL), removeIfCreatedByUs: true)
                queue.flush()

                if trackers[idx].fault == .none {
                    if !trackers[idx].fileExistsOnDisk || trackers[idx].createdAndUntouchedByOutside {
                        trackers[idx].fileExistsOnDisk = false
                        trackers[idx].createdAndUntouchedByOutside = false
                        trackers[idx].expectedRating = nil
                        trackers[idx].expectedLabel = nil
                        trackers[idx].foreignExposure = nil
                    } else {
                        trackers[idx].expectedRating = 0
                        trackers[idx].expectedLabel = nil
                    }
                    trackers[idx].expectUnsaved = false
                    trackers[idx].unsavedEdit = nil
                    #expect(queue.isOwnWrite(trackers[idx].sidecarURL),
                            "seed=\(hex(seed)) round=\(round) photo=\(idx): expected isOwnWrite == true after undo")
                } else {
                    trackers[idx].expectUnsaved = true
                    trackers[idx].unsavedEdit = edit
                    trackers[idx].unsavedRemoveIfCreated = true
                }

            case 5:
                // Outside program (Lightroom / ART) atomically writes or updates a healthy sidecar.
                guard trackers[idx].fault == .none else { break }
                let exposure = String(format: "%+.2f", Double(rng.int(in: -200...200)) / 100.0)
                let outRating = rng.int(in: 0...5)
                let outLabel: String? = rng.bool() ? rng.pick(["Red", "Blue", "Select"]) : nil
                let data = makeOutsideXMP(exposure: exposure, rating: outRating, label: outLabel)
                try atomicReplace(trackers[idx].sidecarURL, with: data, in: dir)

                trackers[idx].fileExistsOnDisk = true
                trackers[idx].createdAndUntouchedByOutside = false
                trackers[idx].foreignExposure = exposure
                trackers[idx].expectedRating = outRating
                trackers[idx].expectedLabel = outLabel
                // Outside atomic replacement changes inode/content; isOwnWrite must be false!
                #expect(!queue.isOwnWrite(trackers[idx].sidecarURL),
                        "seed=\(hex(seed)) round=\(round) photo=\(idx): outside atomic rename misclassified as own write")

            case 6:
                // Transient read-only folder fault (simulates locked SD card), followed by unlock + retryFailed().
                guard trackers[idx].fault == .none else { break }
                // Ensure the edit differs from current disk state so SidecarWriter actually attempts atomicWrite.
                let newRating = ((trackers[idx].expectedRating ?? 0) + 1) % 5 + 1
                let edit = SidecarEdit(rating: newRating, label: .set("Yellow"))
                #expect(chmod(dir.path, 0o555) == 0)
                queue.submit(edit, to: SidecarTarget(primary: trackers[idx].sidecarURL))
                queue.flush()
                #expect(queue.unsavedCount >= 1,
                        "seed=\(hex(seed)) round=\(round): locked folder write did not record failure")
                #expect(chmod(dir.path, 0o755) == 0)

                let retried = queue.retryFailed()
                #expect(retried >= 1, "seed=\(hex(seed)) round=\(round): retryFailed should resubmit locked-folder failure")
                queue.flush()

                trackers[idx].expectedRating = edit.rating
                trackers[idx].expectedLabel = "Yellow"
                if !trackers[idx].fileExistsOnDisk {
                    trackers[idx].fileExistsOnDisk = true
                    trackers[idx].createdAndUntouchedByOutside = true
                }
                trackers[idx].expectUnsaved = false
                trackers[idx].unsavedEdit = nil

            case 7:
                // Inject a persistent refusal fault (symlink, FIFO, or corrupt XML) on a healthy photo.
                guard trackers[idx].fault == .none else { break }
                try? fm.removeItem(at: trackers[idx].sidecarURL)
                trackers[idx].createdAndUntouchedByOutside = false
                trackers[idx].foreignExposure = nil

                switch rng.int(in: 0...2) {
                case 0:
                    let sentinelURL = sentinelDir.appendingPathComponent("sentinel_\(round)_\(idx).xmp")
                    let sentinelData = Data("SENTINEL-\(hex(seed))-\(round)-\(idx)".utf8)
                    try sentinelData.write(to: sentinelURL)
                    try fm.createSymbolicLink(at: trackers[idx].sidecarURL, withDestinationURL: sentinelURL)
                    trackers[idx].fault = .symlink(target: sentinelURL, sentinel: sentinelData)
                case 1:
                    #expect(mkfifo(trackers[idx].sidecarURL.path, 0o644) == 0)
                    trackers[idx].fault = .fifo
                default:
                    let corrupt = Data("<rdf:RDF broken \(round)".utf8)
                    try corrupt.write(to: trackers[idx].sidecarURL)
                    trackers[idx].fault = .corrupt(corrupt)
                }

                let edit = randomEdit(rng: &rng)
                queue.submit(edit, to: SidecarTarget(primary: trackers[idx].sidecarURL))
                queue.flush()
                trackers[idx].expectUnsaved = true
                trackers[idx].unsavedEdit = edit

            default:
                // Recover a faulty photo (if any), then submit a fresh edit to clear the refusal.
                if let brokenIdx = trackers.firstIndex(where: { $0.fault != .none }) {
                    try? fm.removeItem(at: trackers[brokenIdx].sidecarURL)
                    trackers[brokenIdx].fault = .none
                    trackers[brokenIdx].fileExistsOnDisk = false
                    trackers[brokenIdx].createdAndUntouchedByOutside = false
                    trackers[brokenIdx].foreignExposure = nil

                    let recoveryEdit = SidecarEdit(rating: rng.int(in: 1...5), label: .set("Green"))
                    queue.submit(recoveryEdit, to: SidecarTarget(primary: trackers[brokenIdx].sidecarURL))
                    queue.flush()

                    trackers[brokenIdx].fileExistsOnDisk = true
                    trackers[brokenIdx].createdAndUntouchedByOutside = true
                    trackers[brokenIdx].expectedRating = recoveryEdit.rating
                    trackers[brokenIdx].expectedLabel = "Green"
                    trackers[brokenIdx].expectUnsaved = false
                    trackers[brokenIdx].unsavedEdit = nil
                }
            }

            // --- Per-round global invariants ---
            let expectedUnsaved = trackers.filter(\.expectUnsaved).count
            #expect(queue.unsavedCount == expectedUnsaved,
                    "seed=\(hex(seed)) round=\(round): unsavedCount=\(queue.unsavedCount) expected=\(expectedUnsaved)")

            // No leftover `.oxys-tmp-*` temp files after flush.
            let entries = try fm.contentsOfDirectory(atPath: dir.path)
            let temps = entries.filter { $0.contains(SidecarWriter.tempMarker) }
            #expect(temps.isEmpty, "seed=\(hex(seed)) round=\(round): leaked temp files \(temps)")

            for (i, t) in trackers.enumerated() {
                switch t.fault {
                case .none:
                    if t.fileExistsOnDisk {
                        let data = try Data(contentsOf: t.sidecarURL)
                        let props = try XMPReader.parse(data)
                        #expect(props.rating == t.expectedRating && props.label == t.expectedLabel,
                                "seed=\(hex(seed)) round=\(round) photo=\(i): disk=\(props) expected=(\(String(describing: t.expectedRating)), \(String(describing: t.expectedLabel)))")
                        if let exp = t.foreignExposure {
                            let text = String(decoding: data, as: UTF8.self)
                            #expect(text.contains("crs:Exposure2012=\"\(exp)\""),
                                    "seed=\(hex(seed)) round=\(round) photo=\(i): foreign exposure \(exp) lost!")
                        }
                    } else {
                        #expect(!fm.fileExists(atPath: t.sidecarURL.path),
                                "seed=\(hex(seed)) round=\(round) photo=\(i): file should have been removed on undo")
                    }
                case .symlink(let target, let sentinel):
                    // Symlink target must be completely untouched.
                    #expect(try Data(contentsOf: target) == sentinel,
                            "seed=\(hex(seed)) round=\(round) photo=\(i): symlink target was modified!")
                case .corrupt(let original):
                    // Corrupt file must be completely untouched.
                    #expect(try Data(contentsOf: t.sidecarURL) == original,
                            "seed=\(hex(seed)) round=\(round) photo=\(i): corrupt sidecar was overwritten!")
                case .fifo:
                    // Still exists as a FIFO (not replaced).
                    var st = stat()
                    #expect(lstat(t.sidecarURL.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO,
                            "seed=\(hex(seed)) round=\(round) photo=\(i): FIFO was altered!")
                }
            }
        }
    }
}

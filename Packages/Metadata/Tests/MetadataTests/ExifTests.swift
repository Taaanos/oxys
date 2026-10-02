import Foundation
import ImageIO
import Testing
@testable import Metadata

@Suite struct ExifFormatTests {
    @Test func shutter() {
        #expect(ExifFormat.shutter(1.0 / 250) == "1/250 s")
        #expect(ExifFormat.shutter(0.3) == "1/3 s")
        #expect(ExifFormat.shutter(1) == "1 s")
        #expect(ExifFormat.shutter(2.5) == "2.5 s")
        #expect(ExifFormat.shutter(30) == "30 s")
        #expect(ExifFormat.shutter(0) == nil)
    }

    @Test func aperture() {
        #expect(ExifFormat.aperture(2.8) == "f/2.8")
        #expect(ExifFormat.aperture(8) == "f/8")
        #expect(ExifFormat.aperture(1.4) == "f/1.4")
    }

    @Test func exposureCompensation() {
        #expect(ExifFormat.exposureCompensation(0) == "0 EV")
        #expect(ExifFormat.exposureCompensation(1.0 / 3) == "+⅓ EV")
        #expect(ExifFormat.exposureCompensation(-2.0 / 3) == "−⅔ EV")
        #expect(ExifFormat.exposureCompensation(1) == "+1 EV")
        #expect(ExifFormat.exposureCompensation(-1.0 / 3 - 1) == "−1⅓ EV")
        #expect(ExifFormat.exposureCompensation(0.5) == "+0.5 EV")
    }

    @Test func focalLength() {
        #expect(ExifFormat.focalLength(35) == "35 mm")
        #expect(ExifFormat.focalLength(35, equivalent35mm: 35) == "35 mm")
        #expect(ExifFormat.focalLength(23, equivalent35mm: 35) == "23 mm (35 mm equiv.)")
        #expect(ExifFormat.focalLength(8.8) == "8.8 mm")
    }

    @Test func cameraDoesNotRepeatTheMake() {
        #expect(ExifFormat.camera(make: "Canon", model: "Canon EOS 7D") == "Canon EOS 7D")
        #expect(ExifFormat.camera(make: "NIKON CORPORATION", model: "NIKON D850") == "NIKON D850")
        #expect(ExifFormat.camera(make: "SONY", model: "ILCE-7M4") == "SONY ILCE-7M4")
        #expect(ExifFormat.camera(make: nil, model: "X100V") == "X100V")
        #expect(ExifFormat.camera(make: "DJI", model: " ") == "DJI")
    }

    @Test func coordinates() {
        #expect(ExifFormat.coordinates(latitude: 48.8584, longitude: 2.2945) == "48.8584° N, 2.2945° E")
        #expect(ExifFormat.coordinates(latitude: -33.8568, longitude: -70.5) == "33.8568° S, 70.5° W")
    }

    @Test func flashAndModes() {
        #expect(ExifFormat.flash(0x10) == "Did not fire")
        #expect(ExifFormat.flash(0x19) == "Fired")
        #expect(ExifFormat.meteringMode(5) == "Multi-segment")
        #expect(ExifFormat.meteringMode(255) == nil)
        #expect(ExifFormat.whiteBalance(0) == "Auto")
    }
}

@Suite struct ExifParseTests {
    private let properties: [CFString: Any] = [
        kCGImagePropertyPixelWidth: 6000, kCGImagePropertyPixelHeight: 4000,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifLensModel: "RF24-70mm F2.8 L IS USM",
            kCGImagePropertyExifFocalLength: 35.0, kCGImagePropertyExifFNumber: 2.8,
            kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifISOSpeedRatings: [400],
            kCGImagePropertyExifExposureBiasValue: -0.3333, kCGImagePropertyExifMeteringMode: 5,
            kCGImagePropertyExifWhiteBalance: 0, kCGImagePropertyExifFlash: 16,
            kCGImagePropertyExifDateTimeOriginal: "2026:09:30 14:05:09",
        ] as [CFString: Any],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 33.5, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 70.25, kCGImagePropertyGPSLongitudeRef: "W",
            kCGImagePropertyGPSAltitude: 12.0, kCGImagePropertyGPSAltitudeRef: 1,
        ] as [CFString: Any],
    ]

    @Test func readsEveryField() {
        let info = ExifReader.parse(properties)
        #expect(info.camera == "Canon EOS R5")
        #expect(info.lens == "RF24-70mm F2.8 L IS USM")
        #expect(info.focalLength == "35 mm")
        #expect(info.aperture == "f/2.8")
        #expect(info.shutter == "1/250 s")
        #expect(info.iso == "ISO 400")
        #expect(info.exposureCompensation == "−⅓ EV")
        #expect(info.metering == "Multi-segment")
        #expect(info.whiteBalance == "Auto")
        #expect(info.flash == "Did not fire")
        #expect(info.dimensions == "6000 × 4000")
        #expect(info.captureTime != nil)
        #expect(info.gps?.latitude == -33.5)
        #expect(info.gps?.longitude == -70.25)
        #expect(info.gps?.altitude == -12)
        #expect(info.gps?.mapsURL?.absoluteString.contains("ll=-33.5,-70.25") == true)
    }

    @Test func missingValuesAreLeftOut() {
        let info = ExifReader.parse([kCGImagePropertyPixelWidth: 100, kCGImagePropertyPixelHeight: 50])
        #expect(info.fields.map(\.label) == ["Dimensions"])
        #expect(info.gps == nil)
    }

    @Test func fieldsKeepAFixedOrder() {
        let labels = ExifReader.parse(properties).fields.map(\.label)
        #expect(labels == ["Camera", "Lens", "Focal length", "Aperture", "Shutter", "ISO", "Exposure comp.", "White balance",
                           "Metering", "Flash", "Taken", "Dimensions", "GPS"])
    }
}

@Suite struct ExifCacheTests {
    @Test func remembersAFileWithNoExif() {
        let cache = ExifCache()
        let url = URL(fileURLWithPath: "/nonexistent/none.jpg")
        #expect(cache.cached(url) == nil)
        #expect(cache.info(for: url) == nil)
        #expect(cache.cached(url) != nil)   // read once, nothing there
    }

    @Test func staysWithinCapacity() {
        let cache = ExifCache(capacity: 10)
        for i in 0..<25 { _ = cache.info(for: URL(fileURLWithPath: "/nonexistent/\(i).jpg")) }
        let kept = (0..<25).filter { cache.cached(URL(fileURLWithPath: "/nonexistent/\($0).jpg")) != nil }
        #expect(kept.count <= 10)
        #expect(kept.contains(24))
    }
}

@Suite struct ExifCompareTests {
    private func info(focal: String? = "50 mm", aperture: String? = "f/2.8", shutter: String? = "1/250", iso: String? = "ISO 100") -> ExifInfo {
        var info = ExifInfo()
        info.focalLength = focal
        info.aperture = aperture
        info.shutter = shutter
        info.iso = iso
        return info
    }

    @Test func equalSettingsMarkNothing() {
        let fields = info().compareFields(against: info())
        #expect(fields.map(\.label) == ["Focal length", "Aperture", "Shutter", "ISO"])
        #expect(fields.allSatisfy { !$0.differs })
    }

    @Test func aDifferingValueIsMarkedOnBothSides() {
        let a = info(shutter: "1/250"), b = info(shutter: "1/500")
        #expect(a.compareFields(against: b).filter(\.differs).map(\.value) == ["1/250"])
        #expect(b.compareFields(against: a).filter(\.differs).map(\.value) == ["1/500"])
    }

    @Test func otherSettingsAppearOnlyWhenTheyDiffer() {
        var a = info(), b = info()
        a.whiteBalance = "Auto"
        b.whiteBalance = "Auto"
        a.exposureCompensation = "+0.7 EV"
        b.exposureCompensation = "0 EV"
        let labels = a.compareFields(against: b).map(\.label)
        #expect(labels.contains("Exposure comp."))
        #expect(!labels.contains("White balance"))
    }

    @Test func aValueOnlyTheOtherPhotoHasIsADifference() {
        let a = info(focal: nil), b = info(focal: "50 mm")
        let field = a.compareFields(against: b).first { $0.label == "Focal length" }
        #expect(field == CompareField(label: "Focal length", value: "none", differs: true))
        // And the photo that has it is marked too.
        #expect(b.compareFields(against: a).first { $0.label == "Focal length" }?.differs == true)
    }

    @Test func timeSizeAndPlaceAreNeverSettings() {
        var a = info(), b = info()
        a.captureTime = .distantPast
        b.captureTime = .now
        a.dimensions = "6000 × 4000"
        b.dimensions = "4000 × 3000"
        a.fileSize = "20 MB"
        b.fileSize = "30 MB"
        #expect(a.compareFields(against: b).allSatisfy { !$0.differs })
    }

    @Test func withoutTheOtherPhotoNothingIsMarked() {
        let fields = info().compareFields(against: nil)
        #expect(fields.map(\.label) == ["Focal length", "Aperture", "Shutter", "ISO"])
        #expect(fields.allSatisfy { !$0.differs })
    }
}

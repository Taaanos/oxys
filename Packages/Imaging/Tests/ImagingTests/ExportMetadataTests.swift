import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Imaging

/// A flat-color image with `bits` per channel in `space`.
private func flat(width: Int, height: Int, bits: Int, space name: CFString) -> CGImage {
    let space = CGColorSpace(name: name)!
    let info = bits == 16
        ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)!
    context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func properties(of data: Data) -> [CFString: Any] {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
}

/// What a RAW's own properties look like to ImageIO: descriptive tags, and tags that describe the RAW's layout.
private var rawProperties: [CFString: Any] { [
    kCGImagePropertyOrientation: 6,
    kCGImagePropertyPixelWidth: 6000,
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifColorSpace: 65535,
        kCGImagePropertyExifDateTimeOriginal: "2026:09:15 02:39:42", kCGImagePropertyExifPixelXDimension: 6000,
    ] as [CFString: Any],
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-7M4", kCGImagePropertyTIFFOrientation: 6,
        kCGImagePropertyTIFFTileWidth: 512, kCGImagePropertyTIFFTileLength: 512, kCGImagePropertyTIFFPhotometricInterpretation: 32803,
    ] as [CFString: Any],
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.5, kCGImagePropertyGPSLatitudeRef: "N"] as [CFString: Any],
] }

@Test func propertiesAreUprightSizedAndFreeOfRAWLayout() throws {
    let out = ExportMetadata.properties(from: rawProperties, width: 4000, height: 6000)
    #expect(out[kCGImagePropertyOrientation] as? Int == 1)
    let exif = try #require(out[kCGImagePropertyExifDictionary] as? [CFString: Any])
    #expect(exif[kCGImagePropertyExifPixelXDimension] as? Int == 4000)
    #expect(exif[kCGImagePropertyExifPixelYDimension] as? Int == 6000)
    #expect(exif[kCGImagePropertyExifFNumber] as? Double == 2.8)
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:15 02:39:42")
    #expect(exif[kCGImagePropertyExifColorSpace] == nil)       // the encoder knows the profile it embeds
    let tiff = try #require(out[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    #expect(tiff[kCGImagePropertyTIFFMake] as? String == "SONY")
    #expect(tiff[kCGImagePropertyTIFFOrientation] as? Int == 1)
    #expect(tiff[kCGImagePropertyTIFFTileWidth] == nil)
    #expect(tiff[kCGImagePropertyTIFFPhotometricInterpretation] == nil)
    #expect((out[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double == 47.5)
}

@Test func aRAWWithoutExifStillGetsTheDevelopedSize() throws {
    let out = ExportMetadata.properties(from: [:], width: 100, height: 50)
    let exif = try #require(out[kCGImagePropertyExifDictionary] as? [CFString: Any])
    #expect(exif[kCGImagePropertyExifPixelXDimension] as? Int == 100)
}

@Test func jpegIsEightBitSRGBWithTheMetadataWeGave() throws {
    let image = flat(width: 128, height: 96, bits: 8, space: CGColorSpace.sRGB)
    let props = ExportMetadata.properties(from: rawProperties, width: 128, height: 96)
    let data = try DevelopedRenderer.encode(image, as: .jpeg, quality: 0.9, properties: props)
    let read = properties(of: data)
    #expect(read[kCGImagePropertyDepth] as? Int == 8)
    #expect(read[kCGImagePropertyOrientation] as? Int == 1)
    let exif = try #require(read[kCGImagePropertyExifDictionary] as? [CFString: Any])
    #expect(exif[kCGImagePropertyExifFNumber] as? Double == 2.8)
    #expect((read[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String == "ILCE-7M4")
}

@Test func heicIsTenBitDisplayP3WithExifAndGPS() throws {
    try #require(DevelopedRenderer.isSupported(.heic))
    let image = flat(width: 256, height: 192, bits: 16, space: CGColorSpace.displayP3)
    let props = ExportMetadata.properties(from: rawProperties, width: 256, height: 192)
    let data = try DevelopedRenderer.encode(image, as: .heic, quality: 0.8, properties: props)
    let read = properties(of: data)
    #expect(read[kCGImagePropertyDepth] as? Int == 10)
    #expect((read[kCGImagePropertyProfileName] as? String)?.hasPrefix("Display P3") == true)
    #expect(read[kCGImagePropertyOrientation] as? Int == 1)
    #expect(read[kCGImagePropertyPixelWidth] as? Int == 256)
    let exif = try #require(read[kCGImagePropertyExifDictionary] as? [CFString: Any])
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:15 02:39:42")
    #expect((read[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitudeRef] as? String == "N")
}

@Test func heicCarriesTheXMPRatingNextToTheExif() throws {
    let packet = Data("""
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4" xmp:Label="Red"/>\
    </rdf:RDF></x:xmpmeta>
    """.utf8)
    let xmp = try #require(ExportMetadata.developedXMP(from: packet))
    let image = flat(width: 256, height: 192, bits: 16, space: CGColorSpace.displayP3)
    let props = ExportMetadata.properties(from: rawProperties, width: 256, height: 192)
    let data = try DevelopedRenderer.encode(image, as: .heic, quality: 0.8, properties: props, xmp: xmp)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    let rating = try #require(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString))
    #expect(rating as String == "4")
    #expect(((properties(of: data)[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifFNumber] as? Double) == 2.8)
}

@Test func developSettingsAndLayoutTagsLeaveTheXMPButRatingAndKeywordsStay() throws {
    let packet = Data("""
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \
    xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
    xmp:Rating="3" crs:Exposure2012="+1.50" crs:Temperature="5200" tiff:Orientation="6" exif:PixelXDimension="6000"/>\
    </rdf:RDF></x:xmpmeta>
    """.utf8)
    let metadata = try #require(ExportMetadata.developedXMP(from: packet))
    func has(_ path: String) -> Bool { CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) != nil }
    #expect(has("xmp:Rating"))
    #expect(!has("crs:Exposure2012"))
    #expect(!has("crs:Temperature"))
    #expect(!has("tiff:Orientation"))
    #expect(!has("exif:PixelXDimension"))
}

@Test func aSingleQuotedPacketWithATailAfterItsEndParses() throws {
    // How a Sony ARW stores it: single quotes, and the tag's count runs on into the next block.
    let packet = Data("""
    <?xpacket begin='\u{FEFF}' id='W5M0MpCehiHzreSzNTczkc9d'?>
    <x:xmpmeta xmlns:x='adobe:ns:meta/' x:xmptk=''>
    <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
     <rdf:Description rdf:about=''
      xmlns:xmp='http://ns.adobe.com/xap/1.0/'>
      <xmp:Rating>2</xmp:Rating>
     </rdf:Description>
    </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end='w'?>PrintIM\u{0}0300
    """.utf8)
    let metadata = try #require(ExportMetadata.developedXMP(from: packet))
    let rating = try #require(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString))
    #expect(rating as String == "2")
}

@Test func textBetweenTagsKeepsItsQuotes() {
    let packet = Data("<a b='1'>it's x='y' here</a>".utf8)
    #expect(String(decoding: ExportMetadata.doubleQuoted(packet), as: UTF8.self) == "<a b=\"1\">it's x='y' here</a>")
}

@Test func anUnreadablePacketGivesNothing() {
    #expect(ExportMetadata.developedXMP(from: Data("not xml".utf8)) == nil)
}

@Test func theFormatsHaveTheirExtensionsAndTheSystemWritesBoth() {
    #expect(DevelopedFormat.jpeg.fileExtension == "jpg")
    #expect(DevelopedFormat.heic.fileExtension == "heic")
    #expect(DevelopedRenderer.isSupported(.jpeg))
}

import Foundation

/// Joins a RAW and the JPEG or HEIC the camera wrote beside it into one frame (V-10).
public enum RawJpegPairing {
    /// Returns `photos` with each pair merged into the RAW's photo. A pair is one RAW and one JPEG or HEIC with the same
    /// base name in any case. Anything less clear stays as it is: two RAWs with one base name, two companions
    /// (the JPEG then wins and the HEIC stays its own frame), a TIFF.
    public static func pair(_ photos: [Photo]) -> [Photo] {
        var groups: [String: [Int]] = [:]
        for (i, photo) in photos.enumerated() {
            groups[stem(of: photo), default: []].append(i)
        }
        var merged: [Int: Photo.Companion] = [:]
        var absorbed = Set<Int>()
        for indices in groups.values where indices.count > 1 {
            let raws = indices.filter { photos[$0].format.isRaw }
            let companions = indices.filter { photos[$0].format == .jpeg || photos[$0].format == .heic }
            guard raws.count == 1, let raw = raws.first, !companions.isEmpty else { continue }
            let chosen = companions.first { photos[$0].format == .jpeg } ?? companions[0]
            let file = photos[chosen]
            merged[raw] = Photo.Companion(url: file.url, format: file.format, fileSize: file.fileSize,
                                          modificationDate: file.modificationDate)
            absorbed.insert(chosen)
        }
        guard !merged.isEmpty else { return photos }
        var result: [Photo] = []
        result.reserveCapacity(photos.count - absorbed.count)
        for (i, photo) in photos.enumerated() where !absorbed.contains(i) {
            var photo = photo
            photo.companion = merged[i]
            result.append(photo)
        }
        return result
    }

    private static func stem(of photo: Photo) -> String {
        (photo.name as NSString).deletingPathExtension.lowercased()
    }
}

import Foundation

public enum ByteOrder: Sendable, Equatable {
    case little, big
}

/// Bounds-checked, endian-aware reads over memory-mapped bytes. Every read returns
/// nil instead of trapping, because the bytes come from files we don't control.
public struct ByteReader: Sendable {
    public let data: Data
    public var order: ByteOrder

    public init(data: Data, order: ByteOrder = .big) {
        self.data = data
        self.order = order
    }

    public var count: Int { data.count }

    public func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    public func u16(_ offset: Int) -> UInt16? {
        guard let a = u8(offset), let b = u8(offset + 1) else { return nil }
        return order == .little ? UInt16(a) | UInt16(b) << 8 : UInt16(a) << 8 | UInt16(b)
    }

    public func u32(_ offset: Int) -> UInt32? {
        guard let a = u16(offset), let b = u16(offset + 2) else { return nil }
        return order == .little ? UInt32(a) | UInt32(b) << 16 : UInt32(a) << 16 | UInt32(b)
    }

    public func u64(_ offset: Int) -> UInt64? {
        guard let a = u32(offset), let b = u32(offset + 4) else { return nil }
        return order == .little ? UInt64(a) | UInt64(b) << 32 : UInt64(a) << 32 | UInt64(b)
    }

    public func bytes(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= data.count - length else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
    }
}

import Metal
import Synchronization

/// The bytes that overlay masks hold, in every canvas together (P-06). A mask stays while its overlay is off, so the
/// next toggle needs no new texture and no analysis; this is what the memory budget counts for them. The masks add
/// their size when they are made and take it off when they are freed, so the number is right whoever holds them.
public enum OverlayMemory {
    private struct State {
        var bytes = 0
        var onChange: (@Sendable (Int) -> Void)?
    }

    private static let state = Mutex(State())

    /// Bytes held by the masks that exist now.
    public static var bytes: Int { state.withLock { $0.bytes } }

    /// Called, from any thread and outside the lock, with the new total after every change.
    public static func setOnChange(_ handler: (@Sendable (Int) -> Void)?) {
        state.withLock { $0.onChange = handler }
    }

    static func add(_ delta: Int) {
        let (total, handler) = state.withLock { s -> (Int, (@Sendable (Int) -> Void)?) in
            s.bytes += delta
            return (s.bytes, s.onChange)
        }
        handler?(total)
    }
}

extension OverlayMemory {
    /// The bytes of one mask texture, counted while this object lives. A mask made from another one's texture (a burst
    /// reuses it) holds the same object, so the texture is counted once however many masks point at it.
    final class Allocation: Sendable {
        let bytes: Int
        init(_ texture: any MTLTexture) {
            bytes = texture.allocatedSize
            OverlayMemory.add(bytes)
        }
        deinit { OverlayMemory.add(-bytes) }
    }
}

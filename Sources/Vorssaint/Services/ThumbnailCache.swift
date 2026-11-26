// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation
import ImageIO

/// The one downsample every thumbnail consumer goes through. Before this,
/// the clipboard and the window previews each built their own ImageIO options
/// and each decided its own bitmap cost; now one implementation defines both,
/// so a cache's byte budget counts the same pixels everywhere.
enum Downsampler {
    struct Thumbnail {
        let image: NSImage
        /// The decoded bitmap, for callers that need to re-wrap its size.
        let cgImage: CGImage
        /// Bytes the bitmap actually occupies; what caches account.
        let cost: Int
    }

    struct Bitmap {
        let image: CGImage
        let cost: Int
    }

    /// Decodes a file's first image no larger than `maxPixelSize` on its
    /// longest edge. Synchronous: callers keep it off the main thread.
    static func thumbnail(at url: URL, maxPixelSize: CGFloat) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    static func thumbnail(from data: Data, maxPixelSize: CGFloat) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return thumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    static func thumbnail(source: CGImageSource, maxPixelSize: CGFloat) -> Thumbnail? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return Thumbnail(image: NSImage(cgImage: cgImage, size: .zero),
                         cgImage: cgImage,
                         cost: cost(of: cgImage))
    }

    /// The bitmap's real footprint. Derived from the decoded image rather than
    /// from a point size, so Retina and oversized thumbnails are not guessed.
    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// Redraws an already-captured image into a bitmap this process owns,
    /// downscaling to `maxPixelSize` when the source is larger. Window-server,
    /// ScreenCaptureKit and Core Image captures are surface-backed by the
    /// system; caching one directly would pin that surface (and whatever the
    /// OS charges to it) for as long as the thumbnail lives, so capture caches
    /// only ever hold plain copies.
    static func bitmapCopy(of image: CGImage,
                           maxPixelSize: CGFloat = .greatestFiniteMagnitude) -> Bitmap {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxPixelSize / max(width, height, 1))
        let scaledWidth = max(1, Int(width * scale))
        let scaledHeight = max(1, Int(height * scale))
        guard let context = CGContext(data: nil,
                                      width: scaledWidth,
                                      height: scaledHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Bitmap(image: image, cost: cost(of: image)) }
        context.interpolationQuality = scale < 1 ? .high : .default
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(scaledWidth), height: CGFloat(scaledHeight)))
        guard let copy = context.makeImage() else { return Bitmap(image: image, cost: cost(of: image)) }
        return Bitmap(image: copy, cost: cost(of: copy))
    }

    /// Created with caching off: the downsample is the only thing worth
    /// keeping, and ImageIO's own cache would double the footprint.
    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
}

/// A byte-budgeted thumbnail cache shared by every consumer that keeps
/// thumbnails. The budget is per instance — the clipboard keeps 32 MiB and the
/// window previews 64 MiB — but the accounting, the eviction and the
/// memory-pressure response are `ByteBudgetCache`, the same policy the icon
/// caches use. This type adds only the off-main decode lane.
final class ThumbnailCache<Key: Hashable, Value: AnyObject>: @unchecked Sendable {
    typealias Eviction = ByteBudgetCache<Key, Value>.Eviction

    private let store: ByteBudgetCache<Key, Value>
    /// Decodes two at a time at most: a burst of new rows must not hold dozens
    /// of full-size images in memory at once, nor saturate every core.
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.vorssaint.utils.thumbnail-decodes"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(byteBudget: Int, countLimit: Int = .max, eviction: Eviction = .automatic) {
        store = ByteBudgetCache(byteBudget: byteBudget, countLimit: countLimit, eviction: eviction)
    }

    /// The owner opts its instance in. Called once at setup: the monitor is
    /// retained by the cache, so it stops when the cache goes away.
    func monitorMemoryPressure() {
        store.monitorMemoryPressure()
    }

    /// Warning returns half of the budget, critical all of it. The policy is a
    /// plain function so it can be exercised without triggering system pressure.
    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        store.handleMemoryPressure(level)
    }

    /// Drops least recently used entries until the retained bytes fit
    /// `fraction` of the byte budget. A single oversized entry is dropped too,
    /// unlike steady-state eviction: returning memory matters more here.
    func trim(toFraction fraction: Double) {
        store.trim(toFraction: fraction)
    }

    /// Bytes currently accounted. Exposed so the bound can be asserted rather
    /// than assumed.
    var cost: Int { store.cost }

    var count: Int { store.count }

    var keys: Set<Key> { store.keys }

    var costs: [Key: Int] { store.costs }

    /// A synchronous lookup that only touches the lock and the dictionary:
    /// a hit never decodes, and a miss never blocks on a decode. Every hit is
    /// recorded, so a pressure trim drops the least recently used entries for
    /// caller-driven caches too.
    func value(for key: Key) -> Value? {
        store.value(for: key)
    }

    func contains(_ key: Key) -> Bool { store.contains(key) }

    func cost(for key: Key) -> Int? { store.cost(for: key) }

    func insert(_ value: Value, cost: Int, for key: Key) {
        store.insert(value, cost: cost, for: key)
    }

    @discardableResult
    func removeValue(for key: Key) -> Value? {
        store.removeValue(for: key)
    }

    func removeAll() {
        store.removeAll()
    }

    /// A hit answers at once. A miss runs `load` on the shared decode lane; a
    /// caller cancelled before its turn never decodes the image at all. The
    /// load owns its own ImageIO source, so nothing synchronous happens on the
    /// caller's thread.
    func value(for key: Key,
               load: @escaping () -> (value: Value, cost: Int)?) async -> Value? {
        if let cached = store.value(for: key) { return cached }
        let request = DecodeRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                decodeQueue.addOperation {
                    guard !request.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let loaded = load() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.store.insert(loaded.value, cost: loaded.cost, for: key)
                    continuation.resume(returning: loaded.value)
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    private final class DecodeRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}

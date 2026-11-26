// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The byte-budgeted LRU core every image cache shares. The budget is per
/// instance — thumbnails, app icons and menu bar blocks each choose their own —
/// but the accounting, the eviction and the memory-pressure response are this
/// one implementation, so a regression is looked for in one place.
///
/// It stores values directly and never builds them. `ThumbnailCache` layers the
/// off-main decode lane on top; the icon caches only draw and insert.
final class ByteBudgetCache<Key: Hashable, Value: AnyObject>: @unchecked Sendable {
    enum Eviction {
        /// The cache keeps itself inside its byte budget and count limit,
        /// dropping the least recently used entries.
        case automatic
        /// The owner knows which entries are still useful (a window parked in
        /// the Stage Manager strip cannot be recaptured), so it chooses the
        /// victims and the cache only tracks what they cost.
        case callerDriven
    }

    private struct Entry {
        let value: Value
        let cost: Int
        var stamp: UInt64
    }

    private let byteBudget: Int
    private let countLimit: Int
    private let eviction: Eviction
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var storedCost = 0
    private var clock: UInt64 = 0
    /// Held by the cache, so the subscription lives exactly as long as the
    /// owner's cache does. Each cache has its own; nothing is global.
    private var pressureMonitor: MemoryPressureMonitor?

    init(byteBudget: Int, countLimit: Int = .max, eviction: Eviction = .automatic) {
        self.byteBudget = max(0, byteBudget)
        self.countLimit = max(1, countLimit)
        self.eviction = eviction
    }

    /// The owner opts its instance in. Called once at setup: the monitor is
    /// retained by this cache, so it stops when the cache goes away.
    func monitorMemoryPressure() {
        guard pressureMonitor == nil else { return }
        pressureMonitor = MemoryPressureMonitor { [weak self] level in
            self?.handleMemoryPressure(level)
        }
    }

    /// Warning returns half of the budget, critical all of it. The policy is a
    /// plain function so it can be exercised without triggering system pressure.
    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        switch level {
        case .warning:
            trim(toFraction: 0.5)
        case .critical:
            removeAll()
        }
    }

    /// Drops least recently used entries until the retained bytes fit
    /// `fraction` of the byte budget. A single oversized entry is dropped too,
    /// unlike steady-state eviction: returning memory matters more here.
    func trim(toFraction fraction: Double) {
        let target = Int(Double(byteBudget) * min(max(fraction, 0), 1))
        lock.withLock {
            while storedCost > target, !entries.isEmpty {
                guard let victim = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key,
                      let removed = entries.removeValue(forKey: victim)
                else { break }
                storedCost -= removed.cost
            }
        }
    }

    /// Bytes currently accounted. Exposed so the bound can be asserted rather
    /// than assumed.
    var cost: Int { lock.withLock { storedCost } }

    var count: Int { lock.withLock { entries.count } }

    var keys: Set<Key> { lock.withLock { Set(entries.keys) } }

    var costs: [Key: Int] { lock.withLock { entries.mapValues(\.cost) } }

    /// A synchronous lookup that only touches the lock and the dictionary:
    /// a hit never builds, and a miss never blocks on one. Every hit is
    /// recorded, so a pressure trim drops the least recently used entries for
    /// caller-driven caches too.
    func value(for key: Key) -> Value? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock += 1
            entry.stamp = clock
            entries[key] = entry
            return entry.value
        }
    }

    func contains(_ key: Key) -> Bool { lock.withLock { entries[key] != nil } }

    func cost(for key: Key) -> Int? { lock.withLock { entries[key]?.cost } }

    func insert(_ value: Value, cost: Int, for key: Key) {
        let cost = max(0, cost)
        lock.withLock {
            if let previous = entries.removeValue(forKey: key) { storedCost -= previous.cost }
            clock += 1
            entries[key] = Entry(value: value, cost: cost, stamp: clock)
            storedCost += cost
            guard eviction == .automatic else { return }
            evictIfNeeded()
        }
    }

    @discardableResult
    func removeValue(for key: Key) -> Value? {
        lock.withLock {
            guard let removed = entries.removeValue(forKey: key) else { return nil }
            storedCost -= removed.cost
            return removed.value
        }
    }

    /// Invalidation: the owner clears the cache when the images it holds are no
    /// longer valid, and the accounting goes back to zero with them.
    func removeAll() {
        lock.withLock {
            entries.removeAll()
            storedCost = 0
        }
    }

    /// Must be called with `lock` held.
    private func evictIfNeeded() {
        // One entry always stays: an oversized icon or thumbnail is still
        // better than rebuilding it on every draw.
        while entries.count > 1, entries.count > countLimit || storedCost > byteBudget {
            guard let victim = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key,
                  let removed = entries.removeValue(forKey: victim)
            else { break }
            storedCost -= removed.cost
        }
    }
}

enum MemoryPressureLevel {
    case warning
    case critical
}

/// A memory-pressure subscription with an explicit lifetime: whoever creates it
/// keeps it, and releasing it cancels the source. Not a singleton, so a cache
/// only gives memory back while its own feature is alive. The source runs on its
/// own serial queue, and every change it makes goes through the cache's lock.
final class MemoryPressureMonitor {
    private let source: DispatchSourceMemoryPressure

    init(queue: DispatchQueue = DispatchQueue(label: "com.vorssaint.utils.memory-pressure",
                                              qos: .utility),
         handler: @escaping (MemoryPressureLevel) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: queue)
        self.source = source
        source.setEventHandler { [weak source] in
            guard let source else { return }
            handler(source.data.contains(.critical) ? .critical : .warning)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

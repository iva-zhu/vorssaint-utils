// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

/// The policy the drawn-icon caches inherit from the thumbnail cache: the
/// byte budget is enforced, a hit returns the cached instance, system memory
/// pressure hands memory back, and invalidation clears the accounting.
enum IconCachePolicyTests {
    private static let iconSide = 64
    private static let iconCost = iconSide * iconSide * 4

    static func run(_ suite: TestSuite) {
        budgetIsRespected(suite)
        repeatedLookupReturnsTheCachedInstance(suite)
        memoryPressureTrims(suite)
        invalidationClears(suite)
    }

    /// What `CommandBarIconCache` and the menu bar block cache account per
    /// stored image: a 64×64 bitmap, four bytes per pixel.
    private static func icon() -> NSImage {
        NSImage(size: NSSize(width: iconSide, height: iconSide))
    }

    private static func budgetIsRespected(_ suite: TestSuite) {
        let budget = iconCost * 3
        let cache = ByteBudgetCache<String, NSImage>(byteBudget: budget, countLimit: 300)
        var icons: [String: NSImage] = [:]
        for index in 0..<4 {
            let image = icon()
            icons["app-\(index)"] = image
            cache.insert(image, cost: iconCost, for: "app-\(index)")
        }
        suite.expect(cache.cost <= budget, "the byte budget bounds the retained icons")
        suite.expect(cache.count == 3, "the least recently used icon was evicted first")
        suite.expect(cache.value(for: "app-0") == nil, "the oldest icon is the victim")
        suite.expect(cache.value(for: "app-3") === icons["app-3"], "the newest icon is retained")
    }

    private static func repeatedLookupReturnsTheCachedInstance(_ suite: TestSuite) {
        let cache = ByteBudgetCache<String, NSImage>(byteBudget: iconCost * 10, countLimit: 300)
        let image = icon()
        cache.insert(image, cost: iconCost, for: "/Applications/Example.app")
        for _ in 0..<5 {
            suite.expect(cache.value(for: "/Applications/Example.app") === image,
                         "a repeated icon lookup returns the cached instance instead of drawing again")
        }
        suite.expect(cache.cost == iconCost, "lookups do not change the accounted cost")
    }

    private static func memoryPressureTrims(_ suite: TestSuite) {
        let budget = iconCost * 8
        let cache = ByteBudgetCache<String, NSImage>(byteBudget: budget, countLimit: 300)
        var icons: [NSImage] = []
        for index in 0..<8 {
            let image = icon()
            icons.append(image)
            cache.insert(image, cost: iconCost, for: "icon-\(index)")
        }
        suite.expect(cache.cost == budget, "the fixture fills the icon budget")

        cache.handleMemoryPressure(.warning)
        suite.expect(cache.cost <= budget / 2, "a memory warning leaves at most half of the icon budget")
        suite.expect(cache.count == 4, "the least recently used icons are returned to the system")
        suite.expect(cache.value(for: "icon-7") === icons[7], "the newest icon survives the trim")

        cache.handleMemoryPressure(.critical)
        suite.expect(cache.cost == 0 && cache.count == 0, "critical pressure returns every icon")

        let fresh = icon()
        cache.insert(fresh, cost: iconCost, for: "fresh")
        suite.expect(cache.value(for: "fresh") === fresh, "the cache draws and stores again after pressure")
    }

    private static func invalidationClears(_ suite: TestSuite) {
        let cache = ByteBudgetCache<String, NSImage>(byteBudget: iconCost * 10, countLimit: 300)
        for index in 0..<3 {
            cache.insert(icon(), cost: iconCost, for: "stale-\(index)")
        }
        cache.removeAll()
        suite.expect(cache.cost == 0 && cache.count == 0, "invalidation releases the accounted icon bytes")
        suite.expect(cache.value(for: "stale-0") == nil, "a cleared cache returns no stale icon")

        let replacement = icon()
        cache.insert(replacement, cost: iconCost, for: "stale-0")
        suite.expect(cache.value(for: "stale-0") === replacement,
                     "an invalidated key is rebuilt rather than served from the old image")
    }
}

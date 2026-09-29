// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Foundation

/// The combinations the person tied to single rows of the bar.
///
/// An alias makes something faster to find; a shortcut makes it instant, with
/// no bar at all. Both matter, and which one a command deserves is a decision
/// only its owner can make: the thing you run four times a day earns a key,
/// the thing you run weekly does not. Nothing is registered unless the person
/// asked for it, so an untouched install pays nothing.
enum CommandBarRowShortcuts {
    /// Bound global hotkey registrations while leaving room for a shortcut
    /// for every letter and for other commands.
    static let limit = 64

    /// Surfaces that can hold an unanswered row take-over offer. Kept beside
    /// the pure slot store so source isolation is testable without the UI
    /// service singleton.
    enum TakeOverSource: Hashable {
        case captureCard
        case appShortcutsSettings
    }

    /// One unanswered offer per surface. Clearing one question cannot discard
    /// another surface's question.
    struct TakeOverOffers<Value> {
        private var values: [TakeOverSource: Value] = [:]

        subscript(_ source: TakeOverSource) -> Value? {
            get { values[source] }
            set { values[source] = newValue }
        }
    }

    /// A cold catalog may arrive after the person changed their shortcut.
    /// Only the latest request, with its original binding still intact, runs.
    struct PendingAppLaunch {
        private var pending: (key: String, shortcut: GlobalShortcut)?

        mutating func schedule(_ key: String, in shortcuts: [String: GlobalShortcut]) {
            pending = shortcuts[key].map { (key, $0) }
        }

        mutating func cancel() { pending = nil }

        mutating func take(in shortcuts: [String: GlobalShortcut], isAvailable: Bool) -> String? {
            defer { pending = nil }
            guard isAvailable, let pending, shortcuts[pending.key] == pending.shortcut else { return nil }
            return pending.key
        }
    }

    enum AssignmentIssue: Equatable {
        case invalid
        case occupied(String)
        case full
    }

    static func assignmentIssue(_ shortcut: GlobalShortcut, for key: String,
                                in shortcuts: [String: GlobalShortcut]) -> AssignmentIssue? {
        guard isUsable(shortcut) else { return .invalid }
        if let owner = self.key(for: shortcut, in: shortcuts), owner != key {
            return .occupied(owner)
        }
        return hasRoom(for: key, in: shortcuts) ? nil : .full
    }

    static func decode(_ raw: String?) -> [String: GlobalShortcut] {
        guard let raw, let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return stored.compactMapValues(GlobalShortcut.init(storageValue:))
    }

    static func encode(_ shortcuts: [String: GlobalShortcut]) -> String? {
        let stored = shortcuts.mapValues(\.storageValue)
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The map after binding (or clearing, with nil) one row. A combination
    /// already tied to another row moves, because a person pressing keys means
    /// the last thing they said: two rows answering to one combination would
    /// leave one of them dead with no way to tell which.
    static func setting(_ shortcut: GlobalShortcut?,
                        for key: String,
                        in shortcuts: [String: GlobalShortcut]) -> [String: GlobalShortcut] {
        var next = shortcuts
        guard let shortcut else {
            next.removeValue(forKey: key)
            return next
        }
        for (otherKey, other) in next where other == shortcut && otherKey != key {
            next.removeValue(forKey: otherKey)
        }
        guard next[key] != nil || next.count < limit else { return next }
        next[key] = shortcut
        return next
    }

    /// Whether one more row can still be bound. Asked before the keys are
    /// taken, so a full list can say so instead of swallowing the combination.
    static func hasRoom(for key: String, in shortcuts: [String: GlobalShortcut]) -> Bool {
        shortcuts[key] != nil || shortcuts.count < limit
    }

    /// The row a combination belongs to, so the press can be routed without
    /// walking the whole catalog twice.
    static func key(for shortcut: GlobalShortcut, in shortcuts: [String: GlobalShortcut]) -> String? {
        shortcuts.first { $0.value == shortcut }?.key
    }

    /// Whether a paused recording hands this press to the app. Only the keys
    /// the offer's buttons and its keyboard walk use pass through, bare or
    /// with Shift alone (⇧Tab walks focus back): tabbing between the buttons,
    /// activating one, the arrows, and Escape as the standing way out. A
    /// modifier-led combination never does — above all the combination the
    /// question names, whose system action must not fire while the offer
    /// waits. Pure, so the tests can pin the list.
    static func passesWhilePaused(keyCode: Int64, modifiers: GlobalShortcutModifiers) -> Bool {
        let onlyShift = modifiers == [.shift]
        guard modifiers.isEmpty || (onlyShift && keyCode == Int64(kVK_Tab)) else { return false }
        switch Int(keyCode) {
        case kVK_Tab, kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter,
             kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow,
             kVK_Escape:
            return true
        default:
            return false
        }
    }

    /// Routes keys at the take-over offer boundary. Once a safe keyDown has
    /// reached the app, its keyUp must follow even if accepting the offer
    /// resumes the recorder between the two events. Repeats of that held key
    /// are passed only while the offer is still open; otherwise Enter/Space
    /// could leak into the resumed recorder as a new shortcut.
    struct PausedKeyRouter {
        enum Phase { case down, up }
        enum Route: Equatable { case pass, swallow, record }

        private var passedKeyUps = Set<Int64>()

        mutating func route(_ phase: Phase, keyCode: Int64,
                            modifiers: GlobalShortcutModifiers,
                            offerIsOpen: Bool) -> Route {
            switch phase {
            case .up:
                if passedKeyUps.remove(keyCode) != nil { return .pass }
                return offerIsOpen ? .swallow : .record
            case .down:
                if passedKeyUps.contains(keyCode) {
                    return offerIsOpen && passesWhilePaused(keyCode: keyCode, modifiers: modifiers)
                        ? .pass : .swallow
                }
                guard offerIsOpen else { return .record }
                guard passesWhilePaused(keyCode: keyCode, modifiers: modifiers) else { return .swallow }
                passedKeyUps.insert(keyCode)
                return .pass
            }
        }

        mutating func reset() { passedKeyUps.removeAll() }

        /// True while no key the pause let through still owes its release.
        var isEmpty: Bool { passedKeyUps.isEmpty }

        /// The key codes whose release is still owed.
        var owedKeyCodes: Set<Int64> { passedKeyUps }

        /// Drops only the named key's debt: a release the tab technically
        /// owes but the keyboard no longer holds is a lost keyUp, not a key
        /// still held, and must stop costing the app its tap.
        mutating func settleOwedRelease(_ keyCode: Int64) {
            passedKeyUps.remove(keyCode)
        }
    }

    /// The panel-monitor drain for a recording whose event tap could not
    /// exist (no Accessibility). Without the tap the local monitor owns the
    /// offer's keys: a safe keyDown that reaches the app owes its release,
    /// the debt outlives the recording — repeats of that key stay
    /// suppressed and its release passes, whether the offer is still up or
    /// already answered — and a debt the keyboard no longer holds clears
    /// before a fresh press of that key is swallowed for it. The tap-based
    /// drain does the same inside `ShortcutRecordingTap`; this is its
    /// monitor-side twin. Pure, so the tests can walk it without a panel.
    struct FallbackKeyRouter {
        enum Route: Equatable { case pass, swallow, record }

        private var debts = PausedKeyRouter()

        mutating func routeDown(keyCode: Int64, modifiers: GlobalShortcutModifiers,
                                offerIsOpen: Bool,
                                keyIsPhysicallyDown: @autoclosure () -> Bool) -> Route {
            if debts.owedKeyCodes.contains(keyCode) {
                // Whether it is a repeat of the hold or a fresh press while
                // the hold survived its lost release, the keyboard still
                // names this key down: the debt lives, and the press stays
                // suppressed until the release.
                guard keyIsPhysicallyDown() else {
                    // The release was lost (the panel closed mid-hold, say):
                    // the debt names a hold that no longer is, and this
                    // press is a fresh one.
                    debts.settleOwedRelease(keyCode)
                    return freshPress(keyCode: keyCode, modifiers: modifiers,
                                      offerIsOpen: offerIsOpen)
                }
                return .swallow
            }
            return freshPress(keyCode: keyCode, modifiers: modifiers,
                              offerIsOpen: offerIsOpen)
        }

        /// The release of a forwarded key: its debt clears and the event
        /// passes on its way to the app. Any other keyUp passes too.
        mutating func noteKeyUp(_ keyCode: Int64) {
            debts.settleOwedRelease(keyCode)
        }

        var isEmpty: Bool { debts.isEmpty }

        mutating func reset() { debts.reset() }

        private mutating func freshPress(keyCode: Int64, modifiers: GlobalShortcutModifiers,
                                         offerIsOpen: Bool) -> Route {
            switch debts.route(.down, keyCode: keyCode, modifiers: modifiers,
                               offerIsOpen: offerIsOpen) {
            case .pass: return .pass
            case .swallow: return .swallow
            case .record: return .record
            }
        }
    }

    /// Whether a combination is worth registering at all. A bare letter would
    /// take that letter away from every app on the Mac.
    static func isUsable(_ shortcut: GlobalShortcut) -> Bool {
        !shortcut.modifiers.isEmpty
    }
}

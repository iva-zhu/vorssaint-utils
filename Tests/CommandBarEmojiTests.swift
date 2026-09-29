// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Foundation
import SwiftUI

typealias EmojiQueryHabits = CommandBarQueryHabits

/// Catalog, action and learning bodies are extracted from production. Only
/// permissions, panel visibility, typing and the session key are replaced;
/// no keyboard events are sent and preferences live in a disposable domain.
enum CommandBarEmojiContract {
    enum UserDefaults { static var standard: Foundation.UserDefaults! }
    final class Permissions {
        static let shared = Permissions()
        var accessibility = true
    }
    struct CommandBarEntry {
        enum Icon { case symbol(String) }
        enum Trouble { case needsPermission }
        let id: String
        let title: String
        let subtitle: String
        let keywords: String
        let icon: Icon
        let trouble: Trouble?
        let matchTitle: String?
        let run: (Int?) -> Void
        var countsUsage = true
        var keepsBarOpen = false
    }
    enum Catalog {
        typealias CommandBarEntry = CommandBarEmojiContract.CommandBarEntry
        typealias UserDefaults = CommandBarEmojiContract.UserDefaults
        typealias Permissions = CommandBarEmojiContract.Permissions
        static var typed: [String] = []
        static func typeAtCursor(_ text: String) { typed.append(text) }
    }
    typealias CommandBarCatalog = Catalog
    enum CommandBarQueryHabits {
        typealias PreparationCache = EmojiQueryHabits.PreparationCache
        static let key = Data(repeating: 7, count: 32)
        static func prepare(_ query: String, cache: inout PreparationCache) -> EmojiQueryHabits.PreparedQuery {
            EmojiQueryHabits.prepare(query, key: key, cache: &cache)
        }
    }
    final class Service {
        typealias CommandBarEntry = CommandBarEmojiContract.CommandBarEntry
        typealias UserDefaults = CommandBarEmojiContract.UserDefaults
        typealias CommandBarCatalog = CommandBarEmojiContract.Catalog
        typealias CommandBarQueryHabits = CommandBarEmojiContract.CommandBarQueryHabits
        enum Mode { case search, argument, actions }
        var mode = Mode.search
        var query = ":thumb"
        var savedQuery = ""
        var queryBeforeCompletion: String?
        var queryMemoryStep = 0
        var queryMemory = CommandBarQueryMemory()
        var queryHabitStore = CommandBarQueryHabitStoreCache()
        var preparedHabitQuery = CommandBarQueryHabits.PreparationCache()
        var isVisible = true
        var usageCache: [String: CommandBarUse] = [:]
        var queryWhenRun = ""
        var selectionWhenRun = ""
        var selectedText = ""
        func hide() { isVisible = false; query = ""; savedQuery = "" }
    }

    static func run(_ suite: TestSuite) {
        let domain = "com.vorssaint.tests.command-bar-emoji"
        let defaults = Foundation.UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        UserDefaults.standard = defaults
        defer {
            UserDefaults.standard = nil
            defaults.removePersistentDomain(forName: domain)
            Catalog.typed = []
        }
        let tones = CommandBarEmoji.SkinTone.allCases
        suite.expect(!CommandBarEmoji.acceptsSkinTone("👪")
                     && tones.allSatisfy { CommandBarEmoji.applying($0, to: "👪") == "👪" },
                     "family stays unchanged instead of offering unsupported skin tones")
        suite.expect(["👍", "☝️", "🤝", "👫", "👬", "👭", "💏", "💑"].allSatisfy {
            CommandBarEmoji.acceptsSkinTone($0)
        }, "excluding family preserves supported single-person and multi-person tones")

        // Exercise actual row construction, not just the helper used for IDs.
        let originalIDs = CommandBarEmoji.emoji.map { "emoji." + $0.identity }
        let thumbID = "emoji.👍"
        defaults.set(CommandBarPreferences.encodePins([thumbID]), forKey: DefaultsKey.commandBarPins)
        let pins = defaults.string(forKey: DefaultsKey.commandBarPins)
        for tone in tones {
            defaults.set(tone.rawValue, forKey: DefaultsKey.commandBarEmojiSkinTone)
            let rows = Catalog.emojiEntries(bar: .enUS)
            suite.expect(rows.map(\.id) == originalIDs,
                         "\(tone.rawValue) keeps every stored row identity")
            Catalog.typed = []
            rows.forEach { $0.run(nil) }
            suite.expect(zip(rows, Catalog.typed).allSatisfy { $0.title.hasPrefix($1 + "  ") },
                         "\(tone.rawValue) inserts exactly the emoji shown by each row")
            let family = rows.first { $0.id == "emoji.👪" }!
            suite.expect(Service().skinToneActions(for: family).isEmpty,
                         "family has no unsupported alternate actions")
            let thumb = rows.first { $0.id == thumbID }!
            let service = Service()
            let actions = service.skinToneActions(for: thumb)
            suite.expect(actions.count == 5 && Set(actions.map(\.title)).count == 5,
                         "each default offers the other five distinct tones")
            suite.expect(!actions.contains { $0.title == CommandBarEmoji.applying(tone, to: "👍") },
                         "the current default is not duplicated as an alternate")
            for action in actions {
                defaults.removeObject(forKey: DefaultsKey.commandBarUsage)
                defaults.removeObject(forKey: DefaultsKey.commandBarQueryHabits)
                service.queryHabitStore.forgetAll()
                service.mode = .actions
                service.savedQuery = ":thumb"
                service.query = ""
                service.isVisible = true
                action.run()
                let usage = CommandBarUsage.decode(defaults.string(forKey: DefaultsKey.commandBarUsage))
                suite.expect(usage[thumbID]?.count == 1 && usage.count == 1,
                             "a one-off tone records exactly one use under the original emoji")
                suite.expect(service.queryMemory.boost(query: "thumb", id: thumbID) > 0,
                             "a one-off tone learns the search saved before opening actions")
                suite.expect(EmojiQueryHabits.boost(
                    for: thumbID,
                    preparedQuery: EmojiQueryHabits.prepare("thumb", key: CommandBarQueryHabits.key),
                    store: service.queryHabitStore.store, now: Date().timeIntervalSince1970) > 0,
                             "a one-off tone learns searches in memory for the current session")
                suite.expect(defaults.object(forKey: DefaultsKey.commandBarQueryHabits) == nil,
                             "a one-off tone never persists query learning in preferences")
                suite.expect(Service().queryHabitStore.store.isEmpty,
                             "a new service starts without the previous session's query learning")
                suite.expect(!service.isVisible && Catalog.typed.last == action.title,
                             "the one-off action closes the bar and inserts the chosen tone")
                suite.expect(defaults.string(forKey: DefaultsKey.commandBarEmojiSkinTone) == tone.rawValue
                             && defaults.string(forKey: DefaultsKey.commandBarPins) == pins,
                             "one-off insertion preserves the default tone and stored pins")
            }
            // A different preference may change after the one-off insertion.
            defaults.set("emoji", forKey: DefaultsKey.commandBarDisabledSources)
            defaults.set("", forKey: DefaultsKey.commandBarDisabledSources)
            let reopened = Catalog.emojiEntries(bar: .enUS).first { $0.id == thumbID }!
            reopened.run(nil)
            suite.expect(Catalog.typed.last == CommandBarEmoji.applying(tone, to: "👍"),
                         "reopening after another preference change still uses the saved default")
        }

        defaults.removeObject(forKey: DefaultsKey.commandBarUsage)
        let row = Catalog.emojiEntries(bar: .enUS).first { $0.id == thumbID }!
        let normal = Service()
        normal.finish(row, value: nil)
        suite.expect(CommandBarUsage.decode(defaults.string(forKey: DefaultsKey.commandBarUsage))[thumbID]?.count == 1
                     && normal.queryMemory.boost(query: "thumb", id: thumbID) == 1
                     && !normal.isVisible,
                     "normal insertion still records usage and learning once before closing")
        let shortcut = Service()
        shortcut.isVisible = false
        shortcut.query = ""
        shortcut.finish(row, value: nil)
        suite.expect(shortcut.queryMemory == CommandBarQueryMemory()
                     && CommandBarUsage.decode(defaults.string(forKey: DefaultsKey.commandBarUsage))[thumbID]?.count == 2,
                     "a hidden shortcut counts usage without learning an unseen search")
        let argument = Service()
        argument.mode = .argument
        argument.savedQuery = "original"
        argument.query = "42"
        argument.finish(row, value: 42)
        suite.expect(argument.queryMemory.boost(query: "original", id: thumbID) == 1
                     && argument.queryMemory.boost(query: "42", id: thumbID) == 0,
                     "argument execution keeps learning from the saved search")
        var transient = row
        transient.countsUsage = false
        transient.keepsBarOpen = true
        let before = defaults.string(forKey: DefaultsKey.commandBarUsage)
        let open = Service()
        open.finish(transient, value: nil)
        suite.expect(open.isVisible && open.queryMemoryStep == 0
                     && defaults.string(forKey: DefaultsKey.commandBarUsage) == before,
                     "non-learning rows and commands that keep the bar open retain their behavior")

        let payload = SettingsBackupSupport.payload(appVersion: "test", valueFor: defaults.object(forKey:))
        let restored = SettingsBackupSupport.sanitizedSettings(from: payload)
        suite.expect(restored?[DefaultsKey.commandBarEmojiSkinTone] as? String == "dark",
                     "the chosen tone survives backup export and restore validation")

        EmojiGridContract.run(suite)
    }
}

/// The grid's own arithmetic, pinned without touching the real service: the
/// tile sizes a preference reads back as, the column counts the layout
/// derives from them, and the two-dimensional walk the arrow keys ride.
enum EmojiGridContract {
    static func run(_ suite: TestSuite) {
        suite.run("emoji grid sizes") {
            suite.expect(CommandBarEmojiTileSize.resolved(raw: nil) == .medium,
                         "a missing tile size reads as the medium default")
            suite.expect(CommandBarEmojiTileSize.resolved(raw: "") == .medium,
                         "an empty tile size reads as the medium default")
            suite.expect(CommandBarEmojiTileSize.resolved(raw: "bogus") == .medium,
                         "an unknown tile size reads as the medium default")
            suite.expect(CommandBarEmojiTileSize.resolved(raw: "large") == .large
                         && CommandBarEmojiTileSize.resolved(raw: "small") == .small,
                         "a known tile size reads back as itself")
            suite.expect(CommandBarEmojiTileSize.allCases.allSatisfy { $0.tileSize > $0.glyphSize },
                         "every tile leaves room for its caption beside the glyph")
            let columns = CommandBarEmojiTileSize.allCases.map { size in
                max(1, Int((560 - 32 + 6) / (size.tileSize + 6)))
            }
            suite.expect(columns == [7, 5, 4],
                         "the panel fits fewer columns as the tiles grow: got \(columns)")
        }

        suite.run("emoji grid walk") {
            let columns = 5
            let count = 13 // five, five, three: the last row stops early.
            // Straight line moves.
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 7, dx: 1, dy: 0, columns: columns, count: count) == 8,
                         "Right steps over one tile")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 7, dx: -1, dy: 0, columns: columns, count: count) == 6,
                         "Left steps back one tile")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 4, dx: 1, dy: 0, columns: columns, count: count) == 4,
                         "Right at the row's end holds instead of wrapping")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 5, dx: -1, dy: 0, columns: columns, count: count) == 5,
                         "Left at the row's start holds instead of wrapping")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 7, dx: 0, dy: -1, columns: columns, count: count) == 2,
                         "Up jumps a whole row, column-true")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 7, dx: 0, dy: 1, columns: columns, count: count) == 12,
                         "Down into a short last row lands on its own column")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 11, dx: 0, dy: 1, columns: columns, count: count) == 12,
                         "Down from the last row's middle stops at its last tile, column-true")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 2, dx: 0, dy: -1, columns: columns, count: count) == 0,
                         "Up from the first row stops at the top")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 12, dx: 0, dy: 1, columns: columns, count: count) == 12,
                         "Down at the bottom holds")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 11, dx: 1, dy: 0, columns: columns, count: count) == 12,
                         "Right within the short last row reaches its own end")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 12, dx: 1, dy: 0, columns: columns, count: count) == 12,
                         "Right at the short last row's end holds instead of naming an absent tile")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 10, dx: -1, dy: 0, columns: columns, count: count) == 10,
                         "Left at the short last row's start holds, as at any row's start")
            // The degenerate inputs the walk tolerates.
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 7, dx: 0, dy: 0, columns: columns, count: count) == 7,
                         "no step lands nowhere")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 7, dx: 1, dy: 1, columns: columns, count: count) == 13 - 1,
                         "a diagonal is clamped into the row range")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 0, dx: 1, dy: 0, columns: 0, count: count) == 0,
                         "a zero-column layout never moves the selection")
            suite.expect(CommandBarEmojiTileSize.gridTarget(from: 0, dx: 1, dy: 0, columns: columns, count: 0) == 0,
                         "an empty grid never moves the selection")
        }

        suite.run("emoji take-over") {
            let space = GlobalShortcut.commandBarEmojiDefault
            // The picker's own ⌃⌘Space is macOS's until the person agrees to
            // have it: the recorder must ask, never save it as an ordinary key.
            let pickerLive = [LiveSystemShortcut(id: 50, shortcut: space, enabled: true)]
            let pickerIsMacOS = SystemShortcutTakeoverSupport.conflictsWithMacOS(
                space, liveEntries: pickerLive, symbolicHotKeys: nil, held: [],
                role: .commandBarEmoji)
            suite.expect(pickerIsMacOS
                         && GlobalShortcut.conflictsWithSystemShortcut(
                            space, liveEntries: pickerLive, symbolicHotKeys: nil,
                            role: .commandBarEmoji),
                         "the system picker's combination is macOS's until a take-over is agreed")
            suite.expect(SystemShortcutTakeoverSupport.recorderDecision(
                         shortcut: space, conflictsWithMacOS: pickerIsMacOS,
                         takenOver: false, current: space) == .offer,
                         "recording the picker's combination is always an offer, never a silent save")
            suite.expect(GlobalShortcutRole.commandBarEmoji.supportsTakeOver,
                         "the emoji row is a claimant, so it may take a macOS key over")
            // Once accepted, the key the claim holds stays the row's own: a
            // re-recording of the same combination asks nothing and keeps the
            // opt-in, and the claim still names the picker's id so release
            // hands ⌃⌘Space back.
            let pickerHeld = [LiveSystemShortcut(id: 50, shortcut: space, enabled: false)]
            suite.expect(SystemShortcutTakeoverSupport.conflictsWithMacOS(
                         space, liveEntries: pickerHeld, symbolicHotKeys: nil, held: [50],
                         role: .commandBarEmoji),
                         "a picker key this app holds still counts as macOS's for a fresh recording")
            suite.expect(SystemShortcutTakeoverSupport.recorderDecision(
                         shortcut: space, conflictsWithMacOS: true, takenOver: true,
                         current: space) == .save(clearTakeOver: false),
                         "re-recording the accepted key keeps the take-over instead of dropping it")
            suite.expect(SystemShortcutTakeoverSupport.ids(matching: space, in: pickerHeld) == [50],
                         "the emoji claim resolves to exactly the picker's id, so release restores it")
        }

        suite.run("emoji arming") {
            let space = GlobalShortcut.commandBarEmojiDefault
            // The rule the recorder's offer and the sync path share: a
            // combination macOS answers arms only through an agreed take-over,
            // whatever surface asks for the key.
            suite.expect(!SystemShortcutTakeoverSupport.emojiShortcutMayArm(
                         conflictsWithMacOS: true, takenOver: false),
                         "a macOS key never arms without the agreed take-over")
            suite.expect(SystemShortcutTakeoverSupport.emojiShortcutMayArm(
                         conflictsWithMacOS: true, takenOver: true),
                         "an agreed take-over keeps the key armed")
            suite.expect(SystemShortcutTakeoverSupport.emojiShortcutMayArm(
                         conflictsWithMacOS: false, takenOver: false),
                         "a key macOS does not answer arms freely")
            // The bare table check is what made the two arming paths disagree:
            // a key the app itself holds reads free there, while the
            // take-over-aware question — the one the sync path must ask —
            // still names it macOS's.
            let held = [LiveSystemShortcut(id: 50, shortcut: space, enabled: false)]
            suite.expect(!GlobalShortcut.conflictsWithSystemShortcut(
                             space, liveEntries: held, symbolicHotKeys: nil,
                             role: .commandBarEmoji)
                         && SystemShortcutTakeoverSupport.conflictsWithMacOS(
                             space, liveEntries: held, symbolicHotKeys: nil,
                             held: [50], role: .commandBarEmoji),
                         "a held system key reads free to the bare table check, and macOS's to the armed one")
        }

        suite.run("emoji row take-over offer keys") {
            // While an offer stands, the recording holds still: only the keys
            // its buttons use reach the app, and everything else — above all
            // the combination the question names — keeps being swallowed.
            let bare = GlobalShortcutModifiers()
            suite.expect(CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Tab), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Tab), modifiers: [.shift])
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Space), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Return), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_ANSI_KeypadEnter), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_UpArrow), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_DownArrow), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_LeftArrow), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_RightArrow), modifiers: bare)
                         && CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Escape), modifiers: bare),
                         "tabbing (⇧Tab back), activating and the standing way out reach the buttons")
            suite.expect(!CommandBarRowShortcuts.passesWhilePaused(
                             keyCode: Int64(kVK_Space), modifiers: [.control, .command]),
                         "the combination the question names never reaches the system while the offer waits")
            suite.expect(!CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Tab), modifiers: [.command])
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Tab), modifiers: [.control])
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Escape), modifiers: [.command])
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_RightArrow), modifiers: [.shift])
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Space), modifiers: [.shift]),
                         "modifier-led versions of button keys stay swallowed: they are shortcuts, not navigation")
            suite.expect(!CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_ANSI_A), modifiers: bare)
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_ANSI_5), modifiers: bare)
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Delete), modifiers: bare)
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_F5), modifiers: bare)
                         && !CommandBarRowShortcuts.passesWhilePaused(keyCode: Int64(kVK_Shift), modifiers: bare),
                         "letters, digits, modifiers and stray keys stay swallowed while the offer stands")
            suite.expect(!CommandBarRowShortcuts.passesWhilePaused(
                             keyCode: Int64(kVK_Space) + 1, modifiers: bare),
                          "an unknown key code is never a button key")

            var router = CommandBarRowShortcuts.PausedKeyRouter()
            suite.expect(router.route(.down, keyCode: Int64(kVK_Tab), modifiers: bare,
                                       offerIsOpen: true) == .pass
                         && router.route(.up, keyCode: Int64(kVK_Tab), modifiers: bare,
                                         offerIsOpen: true) == .pass,
                         "a button-navigation press reaches the app as a complete key pair")
            suite.expect(router.route(.down, keyCode: Int64(kVK_Space),
                                       modifiers: [.control, .command], offerIsOpen: true) == .swallow
                         && router.route(.up, keyCode: Int64(kVK_Space),
                                         modifiers: bare, offerIsOpen: true) == .swallow,
                         "the system shortcut is swallowed as a complete key pair")

            var acceptedWhileHeld = CommandBarRowShortcuts.PausedKeyRouter()
            suite.expect(acceptedWhileHeld.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                                 offerIsOpen: true) == .pass
                         && acceptedWhileHeld.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                                    offerIsOpen: false) == .swallow
                         && acceptedWhileHeld.route(.up, keyCode: Int64(kVK_Return), modifiers: bare,
                                                    offerIsOpen: false) == .pass
                          && acceptedWhileHeld.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                                     offerIsOpen: false) == .record,
                          "accepting while Return is held passes its release and swallows repeats")

            // Accepting the offer while holding Return ends the recording
            // before the release arrives (`end` keeps this promise). The
            // tap then routes with the recording over and the offer closed:
            // drains only. Repeats stay suppressed, the release forwards,
            // and only the settled drain tears the tap down.
            var acceptedAllTheWay = CommandBarRowShortcuts.PausedKeyRouter()
            suite.expect(acceptedAllTheWay.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                                 offerIsOpen: true) == .pass
                         && !acceptedAllTheWay.isEmpty,
                          "a press the pause forwarded owes its release across the recording's end")
            suite.expect(acceptedAllTheWay.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                                 offerIsOpen: false) == .swallow
                         && acceptedAllTheWay.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                                     offerIsOpen: false) == .swallow,
                          "after the end the held key's autorepeats still stay suppressed")
            suite.expect(acceptedAllTheWay.route(.up, keyCode: Int64(kVK_Return), modifiers: bare,
                                                 offerIsOpen: false) == .pass
                         && acceptedAllTheWay.isEmpty,
                          "the owed release is the last thing the drain forwards")
            suite.expect(acceptedAllTheWay.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                                 offerIsOpen: false) == .record,
                          "once the drain ends a fresh press records again")

            // Two held keys settle independently, in either order: the tap
            // stands down only when neither owes anything.
            var twoHeld = CommandBarRowShortcuts.PausedKeyRouter()
            suite.expect(twoHeld.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                       offerIsOpen: true) == .pass
                         && twoHeld.route(.down, keyCode: Int64(kVK_DownArrow), modifiers: bare,
                                           offerIsOpen: true) == .pass,
                          "two forwarded presses both owe their releases")
            suite.expect(twoHeld.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                        offerIsOpen: false) == .swallow
                         && twoHeld.route(.down, keyCode: Int64(kVK_DownArrow), modifiers: bare,
                                           offerIsOpen: false) == .swallow,
                          "both held keys' repeats stay suppressed after the end")
            suite.expect(twoHeld.route(.up, keyCode: Int64(kVK_DownArrow), modifiers: bare,
                                       offerIsOpen: false) == .pass
                         && !twoHeld.isEmpty,
                          "the first release settles only its own key")
            suite.expect(twoHeld.route(.up, keyCode: Int64(kVK_Return), modifiers: bare,
                                       offerIsOpen: false) == .pass
                         && twoHeld.isEmpty,
                          "the last release settles the drain")

            // A lost keyUp must not pin the tap forever: the watchdog drops
            // the debt of a key the keyboard no longer holds, keeping every
            // other key's debt — and one key's settling never settles
            // another's.
            var droppedRelease = CommandBarRowShortcuts.PausedKeyRouter()
            droppedRelease.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                 offerIsOpen: true)
            droppedRelease.route(.down, keyCode: Int64(kVK_DownArrow), modifiers: bare,
                                 offerIsOpen: true)
            droppedRelease.settleOwedRelease(Int64(kVK_Return))
            suite.expect(droppedRelease.owedKeyCodes == [Int64(kVK_DownArrow)],
                          "a lost release clears only its own key's debt")
            suite.expect(droppedRelease.route(.up, keyCode: Int64(kVK_DownArrow), modifiers: bare,
                                               offerIsOpen: false) == .pass
                         && droppedRelease.isEmpty,
                          "the still-owed release keeps its rescue path and forwards")
            var freshAfterDrop = CommandBarRowShortcuts.PausedKeyRouter()
            freshAfterDrop.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                 offerIsOpen: true)
            freshAfterDrop.settleOwedRelease(Int64(kVK_Return))
            suite.expect(freshAfterDrop.route(.down, keyCode: Int64(kVK_Return), modifiers: bare,
                                               offerIsOpen: false) == .record,
                          "settling a dropped debt lets a fresh press record again")

            var offers = CommandBarRowShortcuts.TakeOverOffers<String>()
            offers[.captureCard] = "card offer"
            offers[.appShortcutsSettings] = "settings offer"
            offers[.appShortcutsSettings] = nil
            suite.expect(offers[.captureCard] == "card offer"
                         && offers[.appShortcutsSettings] == nil,
                         "answering one surface's offer leaves the other surface's offer alone")
        }

        suite.run("emoji drain snapshot race") {
            // The real tap bodies run against a stub state: no tap, no
            // keyboard, no run loop. The race: the watchdog reads a key as
            // "up" (its release was lost), and before that answer lands the
            // key is pressed again — the answer names a drain that has
            // since been re-earned, and must never settle it.
            func key(_ down: Bool, _ code: Int64) -> CGEvent {
                CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            }
            let returnCode = Int64(kVK_Return)

            // A key the pause forwarded still owes its release when the
            // recording ends; its re-press is swallowed and re-earns it.
            let repress = ShortcutRecordingTapContract.Host()
            suite.expect(repress.pausedKeyRouter.route(.down, keyCode: returnCode,
                                                       modifiers: [], offerIsOpen: true) == .pass,
                         "a forwarded press earns its debt")
            let asked = repress.drainGeneration
            suite.expect(repress.handle(type: .keyDown, event: key(true, returnCode)) == nil
                         && repress.drainGeneration == asked + 1,
                         "a re-press of an owed key is swallowed and invalidates the snapshot in flight")
            repress.applyKeyboardSnapshot(keyIsDown: [returnCode: false], draining: nil,
                                          generation: asked)
            suite.expect(!repress.pausedKeyRouter.isEmpty && repress.watchdogArms >= 1,
                         "the stale answer settles nothing and keeps the re-check coming")
            repress.applyKeyboardSnapshot(keyIsDown: [returnCode: false], draining: nil,
                                          generation: asked + 1)
            suite.expect(repress.pausedKeyRouter.isEmpty && repress.tap == nil
                         && repress.drainGeneration == asked + 2,
                         "the fresh answer settles the debt and stands the tap down")

            // The recorded key itself, left draining by `end`, races the
            // same way.
            let draining = ShortcutRecordingTapContract.Host()
            draining.drainingKeyCode = returnCode
            let askedWhileDraining = draining.drainGeneration
            suite.expect(draining.handle(type: .keyDown, event: key(true, returnCode)) == nil
                         && draining.drainGeneration == askedWhileDraining + 1,
                         "a re-press of the draining key re-earns its debt")
            draining.applyKeyboardSnapshot(keyIsDown: [returnCode: false],
                                           draining: returnCode, generation: askedWhileDraining)
            suite.expect(draining.drainingKeyCode == returnCode,
                         "the stale answer must not stand the drain down mid-hold")
            draining.applyKeyboardSnapshot(keyIsDown: [returnCode: false],
                                           draining: returnCode,
                                           generation: askedWhileDraining + 1)
            suite.expect(draining.drainingKeyCode == nil
                         && draining.drainGeneration == askedWhileDraining + 2,
                         "the fresh answer clears the draining key and stands the tap down")

            // A press the drain does not owe passes through untouched and
            // leaves the snapshot live: only owed keys re-earn anything.
            let bystander = ShortcutRecordingTapContract.Host()
            bystander.drainingKeyCode = returnCode
            let askedBystander = bystander.drainGeneration
            suite.expect(bystander.handle(type: .keyDown, event: key(true, Int64(kVK_ANSI_A))) != nil
                         && bystander.drainGeneration == askedBystander,
                         "a press the drain does not owe passes through and keeps the snapshot live")
        }

        suite.run("emoji fallback drain") {
            // The monitor-side twin of the tap's drain: what the panel's
            // own key monitor owes when the recording tap could not exist.
            // Same promise — repeats suppressed, release forwarded, a lost
            // release never swallowing fresh presses.
            let bare = GlobalShortcutModifiers()
            let returnCode = Int64(kVK_Return)

            var router = CommandBarRowShortcuts.FallbackKeyRouter()
            suite.expect(router.routeDown(keyCode: returnCode, modifiers: bare,
                                          offerIsOpen: true,
                                          keyIsPhysicallyDown: true) == .pass
                         && !router.isEmpty,
                         "a forwarded press reaches the offer's buttons and owes its release")
            suite.expect(router.routeDown(keyCode: returnCode, modifiers: bare,
                                          offerIsOpen: false,
                                          keyIsPhysicallyDown: true) == .swallow,
                         "repeats of a forwarded key stay suppressed after the offer closes")
            router.noteKeyUp(returnCode)
            suite.expect(router.isEmpty,
                         "the forwarded key's release settles its debt")
            suite.expect(router.routeDown(keyCode: returnCode, modifiers: bare,
                                          offerIsOpen: false,
                                          keyIsPhysicallyDown: true) == .record,
                         "a fresh press records again once the debt is settled")

            // A lost keyUp must not swallow fresh presses forever: the
            // keyboard no longer holding the forwarded key clears the debt
            // before this press routes, while a re-press of a key the
            // keyboard still holds stays suppressed.
            var lost = CommandBarRowShortcuts.FallbackKeyRouter()
            lost.routeDown(keyCode: returnCode, modifiers: bare,
                           offerIsOpen: true, keyIsPhysicallyDown: true)
            suite.expect(lost.routeDown(keyCode: returnCode, modifiers: bare,
                                        offerIsOpen: false,
                                        keyIsPhysicallyDown: false) == .record
                         && lost.isEmpty,
                         "a fresh press of a key the keyboard no longer holds clears the stale debt")
            lost.routeDown(keyCode: returnCode, modifiers: bare,
                           offerIsOpen: true, keyIsPhysicallyDown: true)
            suite.expect(lost.routeDown(keyCode: returnCode, modifiers: bare,
                                        offerIsOpen: false,
                                        keyIsPhysicallyDown: true) == .swallow,
                         "a re-press of a still-held forwarded key stays suppressed")
            lost.noteKeyUp(returnCode)
            suite.expect(lost.isEmpty, "the re-earned debt still ends with its release")

            // The offer's own rules hold: a stranger stays swallowed, a
            // modifier-led key never reaches the buttons, Escape keeps its
            // way out, and a declined offer leaves the next press free.
            var offer = CommandBarRowShortcuts.FallbackKeyRouter()
            suite.expect(offer.routeDown(keyCode: Int64(kVK_ANSI_A), modifiers: bare,
                                         offerIsOpen: true,
                                         keyIsPhysicallyDown: true) == .swallow,
                         "a stranger stays swallowed while the offer stands")
            suite.expect(offer.routeDown(keyCode: Int64(kVK_RightArrow), modifiers: [.shift],
                                         offerIsOpen: true,
                                         keyIsPhysicallyDown: true) == .swallow,
                         "a modifier-led key never reaches the buttons")
            suite.expect(offer.routeDown(keyCode: Int64(kVK_Escape), modifiers: bare,
                                         offerIsOpen: true,
                                         keyIsPhysicallyDown: true) == .pass,
                         "Escape passes to the offer's way out and owes its release")
            suite.expect(offer.routeDown(keyCode: Int64(kVK_Escape), modifiers: bare,
                                         offerIsOpen: true,
                                         keyIsPhysicallyDown: true) == .swallow,
                         "a held Escape's repeats stay suppressed while the offer waits")
            offer.noteKeyUp(Int64(kVK_Escape))
            suite.expect(offer.routeDown(keyCode: returnCode, modifiers: bare,
                                         offerIsOpen: false,
                                         keyIsPhysicallyDown: false) == .record,
                         "with the offer declined a fresh press records again")
        }
    }
}

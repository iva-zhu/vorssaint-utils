// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// While a shortcut field is listening, every key press belongs to the field.
/// This active tap swallows key events ahead of the system, other apps'
/// global shortcuts and this app's own menu, and hands them to the field.
/// Without it, typing a combination something answers to performs that action
/// instead of landing in the field: recording Command Q would quit an app,
/// and combinations the system consumes could never be recorded at all.
///
/// The tap lives only while a field records, plus the tail of a key still
/// held when recording ends, so its release and autorepeats cannot reach the
/// app as a fresh press of the recorded combination. Only one field ever
/// records at a time (the ShortcutCapture invariant), so one static tap is
/// enough. Main thread only. Without Accessibility, begin fails and the
/// field falls back to plain view events, which is how it always worked.
enum ShortcutRecordingTap {
    private static var tap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?
    private static var handler: ((Int64, GlobalShortcutModifiers, CGEventFlags) -> Void)?
    /// True while the field wants the keys paused (an offer is being
    /// answered): events pass through to the app instead of the handler,
    /// while the tap stays alive and `ShortcutCapture` keeps the app's own
    /// global shortcuts quiet.
    private static var isPaused = false
    /// Routes safe button-navigation events as matched keyDown/keyUp pairs.
    /// It also swallows autorepeats if a button action ends the pause while
    /// its activating key is still held.
    private static var pausedKeyRouter = CommandBarRowShortcuts.PausedKeyRouter()
    /// The key most recently pressed while recording and possibly still down.
    private static var heldKeyCode: Int64?
    /// Set when recording ends with a key still down: its autorepeats and
    /// release keep being swallowed until the release arrives.
    private static var drainingKeyCode: Int64?
    private static var drainWatchdog: DispatchWorkItem?
    /// This tap is created after the super key's and therefore sits ahead of
    /// it, so the trigger key arrives here bare. Reading it the same way the
    /// super key does lets a field record the combination the way it will be
    /// pressed later, instead of asking for the chosen modifiers by hand.
    private static var superState = SuperKeySupport.State()
    private static var observingSession = false

    /// Starts swallowing key events and delivering each fresh press to the
    /// handler. Returns false when the tap cannot exist (no Accessibility),
    /// in which case the caller keeps its ordinary event path.
    @discardableResult
    static func begin(_ newHandler: @escaping (Int64, GlobalShortcutModifiers, CGEventFlags) -> Void) -> Bool {
        drainWatchdog?.cancel()
        drainWatchdog = nil
        drainingKeyCode = nil
        heldKeyCode = nil
        isPaused = false
        pausedKeyRouter.reset()
        superState.reset()
        // Registered before the Accessibility check: ShortcutCapture.begin() has
        // already switched the global shortcuts off, and the resign must give them back.
        if !observingSession {
            observingSession = true
            SessionActivity.shared.onChange { if !$0 { tearDown(); ShortcutCapture.end() } }
        }
        // A tap the system disabled behind our back reads as dead; rebuild.
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            tearDown()
        }
        if tap == nil {
            guard AXIsProcessTrusted() else { return false }
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            guard let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, _ in
                    ShortcutRecordingTap.handle(type: type, event: event)
                },
                userInfo: nil
            ) else { return false }
            tap = created
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
        }
        handler = newHandler
        return true
    }

    /// Safe to call twice and when begin failed. When the recorded key is
    /// still down, the tap lingers just long enough to swallow its release.
    static func end() {
        isPaused = false
        pausedKeyRouter.reset()
        handler = nil
        guard tap != nil else { return }
        if let heldKeyCode {
            drainingKeyCode = heldKeyCode
            armDrainWatchdog()
        } else {
            tearDown()
        }
    }

    /// Hands the keys to the app while the recording holds still — an offer
    /// is being answered, and its buttons must take keyboard focus and
    /// activation. The tap itself stays alive (a rebuild would churn the
    /// system keyboard path, issue #275) and `ShortcutCapture` keeps the
    /// app's own global shortcuts quiet.
    static func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            // Any key still down belongs to the app from here on: its
            // release reaches the app, not this tap, so holding the record
            // would drain a key that already ended.
            heldKeyCode = nil
        } else {
            // Presses already handed to the app keep their release: it passes
            // through even with the pause gone, until the tap ends.
            superState.reset()
        }
    }

    /// Whether a paused recording hands this key to the app. The policy is
    /// the row take-over's own (`CommandBarRowShortcuts.passesWhilePaused`),
    /// so the tap and the panel's monitor can never drift apart.
    static func passesWhilePaused(keyCode: Int64, modifiers: GlobalShortcutModifiers) -> Bool {
        CommandBarRowShortcuts.passesWhilePaused(keyCode: keyCode, modifiers: modifiers)
    }

    /// The drain must outlive the key, not the clock: each swallowed
    /// autorepeat pushes the deadline back, so the tap dies after a second of
    /// silence instead of mid-hold, where the key's remaining repeats would
    /// reach the frontmost app as fresh presses of the recorded combination.
    private static func armDrainWatchdog() {
        drainWatchdog?.cancel()
        let watchdog = DispatchWorkItem { tearDown() }
        drainWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: watchdog)
    }

    private static func tearDown() {
        drainWatchdog?.cancel()
        drainWatchdog = nil
        drainingKeyCode = nil
        heldKeyCode = nil
        pausedKeyRouter.reset()
        handler = nil
        superState.reset()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if SessionActivity.shared.isActive, AXIsProcessTrusted(), let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                DispatchQueue.main.async { tearDown(); ShortcutCapture.end() }
            }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // The pause sits ahead of everything below. A press the policy allows
        // reaches the app and is remembered, so its release follows it; the
        // press itself is never the handler's — and after the pause ends the
        // remembered release still passes through first, so a button key
        // never lands in the recording as a fresh combination. Anything else,
        // above all the combination the question names, keeps being
        // swallowed while the offer waits.
        if isPaused || handler != nil {
            let route = pausedKeyRouter.route(
                type == .keyDown ? .down : .up,
                keyCode: keyCode,
                modifiers: GlobalShortcutModifiers(cgFlags: event.flags),
                offerIsOpen: isPaused)
            switch route {
            case .pass: return Unmanaged.passUnretained(event)
            case .swallow: return nil
            case .record: break
            }
        }
        if let handler {
            // Holding the super key while recording means the modifiers it
            // stands for, and the key holding them is never the shortcut.
            var heldModifiers: GlobalShortcutModifiers = []
            if SuperKeyService.isEngaged {
                let superEvent: SuperKeySupport.Event
                if keyCode == SuperKeySupport.triggerKeyCode {
                    let timestamp = UInt64(event.timestamp)
                    superEvent = type == .keyDown
                        ? .triggerDown(
                            isRepeat: isRepeat,
                            hasPrimaryModifiers: !GlobalShortcutModifiers(cgFlags: event.flags).isEmpty,
                            timestamp: timestamp
                        )
                        : .triggerUp(timestamp: timestamp)
                } else {
                    superEvent = .otherKey
                }
                switch superState.decide(superEvent) {
                case .swallow, .soloTap(repeated: _), .soloHold(repeated: _): return nil
                case .addModifiers: heldModifiers = SuperKeyService.shared.modifiers
                case .pass, .interceptAndRemap: break
                }
            }
            if type == .keyDown {
                heldKeyCode = keyCode
                // Autorepeats of a held key are swallowed but never re-fed:
                // the field wants the press, not a stream of it.
                if !isRepeat {
                    handler(keyCode, GlobalShortcutModifiers(cgFlags: event.flags).union(heldModifiers),
                            event.flags)
                }
            } else if keyCode == heldKeyCode {
                heldKeyCode = nil
            }
            return nil
        }
        if let drainingKeyCode, keyCode == drainingKeyCode {
            if type == .keyUp {
                tearDown()
            } else {
                armDrainWatchdog()
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

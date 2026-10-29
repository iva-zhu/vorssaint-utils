// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import UniformTypeIdentifiers

/// Settings backup: writes the exportable preferences to a plist and brings
/// one back in. Importing replaces the current preferences and relaunches, so
/// every service, panel and status item comes back from a clean state instead
/// of chasing 25 live re-syncs.
enum SettingsBackup {
    /// Shows the save panel and writes the file. nil = user cancelled.
    @discardableResult
    static func runExportPanel() -> Bool? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Vorssaint Settings.plist"
        panel.allowedContentTypes = [.propertyList]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        ScratchpadService.shared.prepareForSettingsBackup()
        return write(to: url)
    }

    /// Writes the backup file; false when it could not be saved.
    static func write(to url: URL) -> Bool {
        let defaults = UserDefaults.standard
        // object(forKey:) sees through to registered defaults, so the file is
        // a complete snapshot: importing it reproduces this exact setup even
        // where the user never touched a control.
        let payload = SettingsBackupSupport.payload(appVersion: AppInfo.version) {
            defaults.object(forKey: $0)
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: payload,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Shows the open panel; nil = user cancelled.
    static func runImportPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList, .xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Reads and validates a backup; nil when the file is not one of ours.
    static func readSettings(at url: URL) -> [String: Any]? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var coordinatedData: Data?
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readURL in
            coordinatedData = try? Data(contentsOf: readURL)
        }
        guard let data = coordinatedData ?? (try? Data(contentsOf: url)),
              let payload = try? PropertyListSerialization.propertyList(from: data,
                                                                        options: [],
                                                                        format: nil) as? [String: Any]
        else { return nil }
        return SettingsBackupSupport.sanitizedSettings(from: payload)
    }

    /// Applies the file's values and relaunches.
    static func applyAndRelaunch(settings: [String: Any]) {
        ScratchpadService.shared.prepareForSettingsRestore()
        apply(settings: settings)
        FeatureRuntime.shared.relaunchApp()
    }

    /// Clears the exportable keys (unset ones fall back to their registered
    /// defaults) and writes the file's values.
    static func apply(settings: [String: Any]) {
        let defaults = UserDefaults.standard
        let localRecorderPresets = defaults.data(forKey: DefaultsKey.recorderEditorPresets)
        let localWatermark = defaults.string(forKey: DefaultsKey.screenshotWatermarkStyle)
        let localWatermarkPresets = defaults.string(forKey: DefaultsKey.screenshotWatermarkPresets)
        // A backup carries only the portable half of an exception list: the
        // path of a program that is not an app is authority on one Mac and is
        // filtered out on export (issue #1009). The clear below covers every
        // exported key, so without carrying that half across by hand, applying
        // a backup would delete those entries outright -- including on the Mac
        // the file was written on, where nothing about them was ever wrong.
        // The thumbnail pause lists take such paths too (issue #3033).
        let carried = (MouseExceptionScope.allCases.map(\.defaultsKey)
                       + SettingsBackupSupport.thumbnailPauseListKeys)
            .reduce(into: [String: [String]]()) { out, key in
                out[key] = SettingsBackupSupport.pathIdentities(in: defaults.stringArray(forKey: key) ?? [])
            }
        let windowLayoutPaths = SettingsBackupSupport.pathIdentities(
            in: defaults.stringArray(forKey: DefaultsKey.windowLayoutIgnoredApps) ?? [])
        for key in SettingsBackupSupport.keysToClear(whenImporting: settings) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in settings {
            defaults.set(value, forKey: key)
        }
        if let shared = SettingsBackupSupport.sharedSwitcherPauseList(in: settings) {
            defaults.set(shared, forKey: DefaultsKey.switcherPreviewExcludedApps)
        }
        if let restored = settings[DefaultsKey.recorderEditorPresets] as? Data {
            defaults.set(SettingsBackupSupport.preservingLocalPresetImages(
                restored: restored, local: localRecorderPresets), forKey: DefaultsKey.recorderEditorPresets)
        }
        defaults.set(SettingsBackupSupport.restoredScreenshotWatermark(
            restored: settings[DefaultsKey.screenshotWatermarkStyle] as? String,
            local: localWatermark), forKey: DefaultsKey.screenshotWatermarkStyle)
        defaults.set(SettingsBackupSupport.restoredScreenshotWatermarkPresets(
            restored: settings[DefaultsKey.screenshotWatermarkPresets] as? String,
            local: localWatermarkPresets), forKey: DefaultsKey.screenshotWatermarkPresets)
        for (key, paths) in carried where !paths.isEmpty {
            defaults.set(SettingsBackupSupport.restoredExceptionList(
                restored: defaults.stringArray(forKey: key) ?? [],
                carried: paths), forKey: key)
        }
        if !windowLayoutPaths.isEmpty {
            defaults.set(SettingsBackupSupport.restoredExceptionList(
                restored: defaults.stringArray(forKey: DefaultsKey.windowLayoutIgnoredApps) ?? [],
                carried: windowLayoutPaths), forKey: DefaultsKey.windowLayoutIgnoredApps)
        }
    }

    /// `--export-settings FILE` and `--import-settings FILE`, for scripts and
    /// dotfiles. Runs before the app starts, so no menu bar item or window
    /// appears.
    static func runCommandAndExit(_ command: SettingsBackupSupport.Command) -> Never {
        switch command {
        case .conflictingFlags:
            failCommand("use exactly one settings backup flag")
        case .missingFile(let flag):
            failCommand("\(flag) needs a file path")
        case .export(let path):
            Defaults.register()
            guard write(to: URL(fileURLWithPath: path)) else { failCommand("could not save \(path)") }
            print("SETTINGS: exported to \(path)")
        case .import(let path):
            // A running app keeps the settings it already loaded and saves some
            // of them again, over the imported ones. The Import button
            // relaunches for the same reason.
            let pid = ProcessInfo.processInfo.processIdentifier
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains { $0.processIdentifier != pid }
            guard !running else { failCommand("quit the app before importing settings") }
            guard let settings = readSettings(at: URL(fileURLWithPath: path)) else {
                failCommand("\(path) is not a valid Vorssaint backup")
            }
            Defaults.register()
            apply(settings: settings)
            // The process exits next; make sure the writes reach the store.
            UserDefaults.standard.synchronize()
            print("SETTINGS: imported from \(path)")
        }
        exit(EXIT_SUCCESS)
    }

    private static func failCommand(_ message: String) -> Never {
        FileHandle.standardError.write(Data("SETTINGS: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

/// Automatic settings export (issue #497): when the user opts in on the
/// Advanced page, the same backup the Export button writes is rewritten to a
/// chosen file as preferences change. Dotfiles users point the file at a
/// tracked path and keep the app's setup in a repository; Import settings and
/// `--import-settings` read the very same file back. A burst of changes waits
/// out a short debounce and lands as one file write, not one per row.
final class SettingsAutoExporter {
    static let shared = SettingsAutoExporter()
    /// Idle time after the last preference write before the file is rewritten.
    static let debounce: TimeInterval = 2

    private var schedule = SettingsBackupSupport.SettingsAutoExportSchedule()
    private var workItem: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    /// The file the mirror writes into, or nil when the option is off or the
    /// saved path is not usable.
    private func writeURL() -> URL? {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.settingsAutoExportEnabled) else {
            return nil
        }
        return SettingsBackupSupport.autoExportURL(
            path: UserDefaults.standard.string(forKey: DefaultsKey.settingsAutoExportPath) ?? "")
    }

    /// One observer for the life of the app. Writes only ever happen when the
    /// option is on and a file was chosen, so nobody who never turned the
    /// mirror on pays for it.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
    }

    /// Reacts to one preference change: without a usable file, drop anything
    /// pending; with one, let a burst finish settling before it lands on disk
    /// as a single write.
    func settingsChanged() {
        guard let url = writeURL() else {
            workItem?.cancel()
            workItem = nil
            schedule.writeSettled()
            return
        }
        scheduleWrite(to: url)
    }

    private func scheduleWrite(to url: URL) {
        // The first change of a burst marks the write; any change arriving
        // while that write waits restarts the debounce, so the file lands on
        // disk once, a beat after the burst has actually settled.
        _ = schedule.changeArrived()
        workItem?.cancel()
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            workItem = nil
            writeSettings(to: url)
        }
        workItem = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: pending)
    }

    /// A change still inside its debounce would die with the process. Write it
    /// out now (called from applicationWillTerminate).
    func writePendingNow() {
        guard schedule.writeIsPending, let url = writeURL() else { return }
        workItem?.cancel()
        workItem = nil
        schedule.writeSettled()
        writeSettings(to: url)
    }

    private func writeSettings(to url: URL) {
        // The scratchpad document is part of the export; the manual Export
        // button first pushes its pending edits into the snapshot, so the
        // mirror sends the same complete file.
        ScratchpadService.shared.prepareForSettingsBackup()
        schedule.writeSettled()
        _ = SettingsBackup.write(to: url)
    }
}

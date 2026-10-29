// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// The automatic settings export (issue #497): the mirror's coalescing, its
// file resolution, that its switch and file travel with the backup, and that
// every language labels it.
enum SettingsAutoExportTests {
    static func run(_ suite: TestSuite) {
        // MARK: A burst of changes is one write, not one per row

        var burst = SettingsBackupSupport.SettingsAutoExportSchedule()
        var scheduled = 0
        for _ in 0..<30 where burst.changeArrived() {
            scheduled += 1
        }
        suite.expect(scheduled == 1 && burst.writeIsPending,
                     "a burst of preference changes schedules exactly one mirror write")

        var firstOfMany = SettingsBackupSupport.SettingsAutoExportSchedule()
        suite.expect(firstOfMany.changeArrived(),
                     "the first change of a burst schedules the write")
        suite.expect(!firstOfMany.changeArrived(),
                     "changes behind the pending write are absorbed by it")

        var resumed = SettingsBackupSupport.SettingsAutoExportSchedule()
        _ = resumed.changeArrived()
        resumed.writeSettled()
        suite.expect(!resumed.writeIsPending && resumed.changeArrived(),
                     "once a write has landed, the next change schedules again")

        suite.expect(SettingsBackupSupport.SettingsAutoExportSchedule() == .init(),
                     "a fresh schedule has no write pending")

        // MARK: Which file the mirror may write

        suite.expect(SettingsBackupSupport.autoExportURL(path: "") == nil,
                     "an empty path leaves the mirror without a file")
        suite.expect(SettingsBackupSupport.autoExportURL(path: "Library/vorssaint.plist") == nil,
                     "a relative path is not a mirror target")
        suite.expect(SettingsBackupSupport.autoExportURL(path: "~/dotfiles/vorssaint.plist",
                                                         home: "/Users/kit")
                == URL(fileURLWithPath: "/Users/kit/dotfiles/vorssaint.plist"),
             "a tilde path expands to the home directory")
        suite.expect(SettingsBackupSupport.autoExportURL(path: "/Users/kit/dotfiles/v.plist",
                                                         home: "/Users/kit")
                == URL(fileURLWithPath: "/Users/kit/dotfiles/v.plist"),
             "an absolute path stands in as the mirror target")

        // MARK: The mirror travels with the backup

        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.settingsAutoExportEnabled)
                && SettingsBackupSupport.exportKeys().contains(DefaultsKey.settingsAutoExportPath),
             "the mirror's switch and file are part of the settings backup (issue #497)")
        suite.expect((Defaults.registeredDefaults[DefaultsKey.settingsAutoExportEnabled] as? Bool) == false
                && (Defaults.registeredDefaults[DefaultsKey.settingsAutoExportPath] as? String) == "",
             "the mirror ships off and without a file")

        do {
            let payload = SettingsBackupSupport.payload(appVersion: "test") { key in
                key == DefaultsKey.settingsAutoExportEnabled ? true
                    : key == DefaultsKey.settingsAutoExportPath ? "~/dotfiles/vorssaint.plist"
                    : nil
            }
            let restored = SettingsBackupSupport.sanitizedSettings(from: payload)
            suite.expect(restored?[DefaultsKey.settingsAutoExportEnabled] as? Bool == true
                    && restored?[DefaultsKey.settingsAutoExportPath] as? String == "~/dotfiles/vorssaint.plist",
                 "a mirror switch and file in a backup read back whole")
        }

        // MARK: Every language labels the mirror

        for language in AppLanguage.allCases {
            let strings = FeatureStrings.backup(language)
            LocalizationTests.check(strings, against: FeatureStrings.backup(.enUS),
                                    name: "backup strings \(language.rawValue)", suite: suite)
            suite.expect(!strings.autoExportToggle.isEmpty && !strings.autoExportChoose.isEmpty
                    && !strings.autoExportCaption.isEmpty,
                 "the automatic export is labeled in \(language.rawValue)")
        }
    }
}

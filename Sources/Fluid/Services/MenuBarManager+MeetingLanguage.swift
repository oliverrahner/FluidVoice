import AppKit

// FORK(meeting-language): see FORK.md, feature "Quick meeting language toggle".
// A "Meeting Language" submenu next to "Start Meeting Recording", so switching between languages
// never needs the FluidMeet settings sheet.
extension MenuBarManager {
    static let meetingLanguageMenuItemIdentifier = NSUserInterfaceItemIdentifier("fork.meetingLanguage")

    func makeMeetingLanguageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Meeting Language", action: nil, keyEquivalent: "")
        item.identifier = Self.meetingLanguageMenuItemIdentifier
        item.submenu = NSMenu(title: "Meeting Language")
        self.populateMeetingLanguageMenu(item)
        return item
    }

    func refreshMeetingLanguageMenu(in menu: NSMenu?) {
        guard let item = menu?.items.first(where: { $0.identifier == Self.meetingLanguageMenuItemIdentifier }) else { return }
        self.populateMeetingLanguageMenu(item)
    }

    private func populateMeetingLanguageMenu(_ item: NSMenuItem) {
        item.isHidden = !SettingsStore.shared.fluidMeetEnabled
        guard let submenu = item.submenu else { return }
        submenu.removeAllItems()

        let current = MeetingLanguageChoice.storedChoice(SettingsStore.shared.meetingRecordingDefaults.languageCode)
        var codes = MeetingLanguageChoice.quickCodes
        if !codes.contains(current) { codes.append(current) }
        for code in codes {
            let entry = NSMenuItem(
                title: MeetingLanguageChoice.displayName(for: code),
                action: #selector(self.selectMeetingLanguage(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = code
            entry.state = code == current ? .on : .off
            submenu.addItem(entry)
            if code == MeetingLanguageChoice.autoCode { submenu.addItem(.separator()) }
        }
        item.title = "Meeting Language: \(MeetingLanguageChoice.shortName(for: current))"
    }

    @objc private func selectMeetingLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        MeetingLanguageChoice.save(code)
        self.refreshMeetingLanguageMenu(in: sender.menu?.supermenu)
    }
}

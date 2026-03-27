//
//  ControlItem.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine

// MARK: - ControlItem

/// A status item that controls a section in the menu bar.
@MainActor
final class ControlItem {
    /// An identifier for a control item.
    enum Identifier: String, CaseIterable {
        /// The identifier for the control item for the visible section.
        case visible = "Thaw.ControlItem.Visible"
        /// The identifier for the control item for the hidden section.
        case hidden = "Thaw.ControlItem.Hidden"
        /// The identifier for the control item for the always-hidden section.
        case alwaysHidden = "Thaw.ControlItem.AlwaysHidden"

        /// A tag for the control item with this identifier.
        var tag: MenuBarItemTag {
            switch self {
            case .visible: .visibleControlItem
            case .hidden: .hiddenControlItem
            case .alwaysHidden: .alwaysHiddenControlItem
            }
        }

        /// Returns the length associated with this identifier and
        /// the given hiding state.
        func length(for state: HidingState) -> CGFloat {
            switch self {
            case .visible:
                Lengths.standard
            case .hidden, .alwaysHidden:
                switch state {
                case .showSection: Lengths.standard
                case .hideSection: Lengths.expanded
                }
            }
        }
    }

    /// A hiding state for a control item.
    enum HidingState {
        case showSection
        case hideSection
    }

    /// A namespace for control item lengths.
    private enum Lengths {
        static let standard: CGFloat = NSStatusItem.variableLength
        /// Small non-zero width keeps items on-screen for image capture
        /// while providing clear section boundaries for `findSection()`.
        /// The shield panel prevents clicks from reaching actual items.
        static let expanded: CGFloat = 1
    }

    /// Storage for a control item's underlying status item.
    private final class StatusItemStorage {
        let statusItem: NSStatusItem
        let constraint: NSLayoutConstraint?

        /// Creates a new storage instance.
        @MainActor
        init(controlItem: ControlItem) {
            ControlItemDefaults.preflightSetup(for: controlItem)

            self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
            self.statusItem.autosaveName = controlItem.identifier.rawValue

            if let button = statusItem.button {
                if let contentView = button.window?.contentView {
                    let constraints = contentView.constraintsAffectingLayout(for: .horizontal)
                    if let constraint = constraints.first(where: Predicates.controlItemConstraint(button: button)) {
                        assert(constraints.filter(Predicates.controlItemConstraint(button: button)).count == 1)
                        self.constraint = constraint
                    } else {
                        self.constraint = nil
                    }

                    NSLayoutConstraint.activate([
                        button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                    ])
                } else {
                    self.constraint = nil
                }

                button.target = controlItem
                button.action = #selector(controlItem.performAction)
                button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            } else {
                self.constraint = nil
            }
        }

        deinit {
            removeStatusItem()
        }

        /// Removes the status item from the status bar.
        private func removeStatusItem() {
            // Removing the status item has the unwanted side effect of
            // deleting the preferred position. Cache and restore it,
            // but only for non-section-divider items.
            let autosaveName = statusItem.autosaveName as String
            let isSectionDivider = ControlItemDefaults.isSectionDivider(autosaveName: autosaveName)
            let cached = ControlItemDefaults[.preferredPosition, autosaveName]
            NSStatusBar.system.removeStatusItem(statusItem)
            if !isSectionDivider {
                ControlItemDefaults[.preferredPosition, autosaveName] = cached
            }
        }
    }

    /// The control item's hiding state (`@Published`).
    @Published var state = HidingState.hideSection

    /// The control item's window (`@Published`).
    @Published private(set) var window: NSWindow?

    /// The control item's frame (`@Published`).
    @Published private(set) var frame: CGRect?

    /// The control item's screen (`@Published`).
    @Published private(set) var screen: NSScreen?

    /// The control item's frame, if it is onscreen (`@Published`).
    @Published private(set) var onScreenFrame: CGRect?

    /// The control item's identifier.
    let identifier: Identifier

    /// Lazy storage for the control item's underlying status item.
    /// Not created for the visible control item (rendered by the overlay).
    private lazy var storage: StatusItemStorage? = {
        guard identifier != .visible else { return nil }
        return StatusItemStorage(controlItem: self)
    }()

    /// Spacer items used to extend hidden/always-hidden width on ultra-wide displays.
    private var spacerItems = [NSStatusItem]()

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The control item's underlying status item.
    /// `nil` for the visible control item (rendered by the overlay).
    private var statusItem: NSStatusItem? {
        storage?.statusItem
    }

    /// A horizontal constraint for the control item's content view.
    private var constraint: NSLayoutConstraint? {
        storage?.constraint
    }

    /// A Boolean value that indicates whether the control item serves as
    /// a divider between sections.
    var isSectionDivider: Bool {
        identifier != .visible
    }

    /// A Boolean value that indicates whether the control item is currently
    /// displayed in the menu bar. The visible control item is always
    /// considered "added" since the overlay renders it virtually.
    var isAddedToMenuBar: Bool {
        if identifier == .visible { return true }
        return statusItem?.isVisible ?? false
    }

    /// The corresponding section name for the control item.
    var sectionName: MenuBarSection.Name {
        switch identifier {
        case .visible: .visible
        case .hidden: .hidden
        case .alwaysHidden: .alwaysHidden
        }
    }

    /// Creates a control item with the given identifier.
    init(identifier: Identifier) {
        self.identifier = identifier
    }

    /// Performs the initial setup of the control item.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the internal observers for the control item.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // The visible control item has no physical status item —
        // the overlay panel handles rendering and interaction.
        // Only set up physical observers for hidden/alwaysHidden.
        if identifier == .visible {
            // Enable the hotkey immediately (visible section is always enabled).
            if let menuBarManager = appState?.menuBarManager,
               let section = menuBarManager.section(withName: sectionName),
               let hotkey = section.hotkey
            {
                hotkey.enable()
            }
        }

        if let statusItem, identifier != .visible {
            $state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateStatusItem()
                }
                .store(in: &c)

            statusItem.publisher(for: \.isVisible)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isVisible in
                    guard
                        let self,
                        let menuBarManager = appState?.menuBarManager,
                        let section = menuBarManager.section(withName: sectionName),
                        let hotkey = section.hotkey
                    else {
                        return
                    }
                    if isVisible {
                        hotkey.enable()
                    } else {
                        hotkey.disable()
                    }
                }
                .store(in: &c)

            statusItem.publisher(for: \.button).removeNil()
                .flatMap { $0.publisher(for: \.window) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] window in
                    self?.window = window
                }
                .store(in: &c)

            $window.removeNil()
                .flatMap { $0.publisher(for: \.frame) }
                .removeDuplicates()
                .debounce(for: 0.05, scheduler: DispatchQueue.main)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] frame in
                    self?.frame = frame
                }
                .store(in: &c)

            $window.removeNil()
                .flatMap { $0.publisher(for: \.screen) }
                .debounce(for: 0.05, scheduler: DispatchQueue.main)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] screen in
                    self?.screen = screen
                }
                .store(in: &c)

            $screen.removeNil()
                .flatMap { $0.publisher(for: \.frame) }
                .combineLatest($frame.removeNil())
                .removeDuplicates()
                .debounce(for: 0.05, scheduler: DispatchQueue.main)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] screenFrame, frame in
                    guard let self else {
                        return
                    }
                    if screenFrame.intersects(frame) {
                        onScreenFrame = frame
                    } else {
                        onScreenFrame = nil
                    }
                }
                .store(in: &c)
        }

        if let appState {
            if identifier != .visible {
                appState.$isDraggingMenuBarItem
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] isDragging in
                        guard let self else {
                            return
                        }
                        if isDragging {
                            updateStatusItem()
                        }
                    }
                    .store(in: &c)
            }

            if identifier == .alwaysHidden, let statusItem {
                appState.settings.advanced.$enableAlwaysHiddenSection
                    .combineLatest(statusItem.publisher(for: \.isVisible))
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] shouldEnable, _ in
                        guard let self else {
                            return
                        }
                        if shouldEnable {
                            addToMenuBar()
                        } else {
                            removeFromMenuBar()
                        }
                    }
                    .store(in: &c)
            }

            if isSectionDivider {
                appState.settings.advanced.$sectionDividerStyle
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.updateStatusItem()
                    }
                    .store(in: &c)
            }
        }

        cancellables = c
    }

    /// Updates the appearance of the status item using the current hiding state.
    private func updateStatusItem() {
        // The visible control item is rendered by the overlay — no physical update needed.
        guard identifier != .visible else { return }

        guard
            let appState,
            let button = statusItem?.button
        else {
            return
        }

        button.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        button.title = ""
        button.image = nil

        switch identifier {
        case .visible:
            break // Handled by overlay panel.
        case .hidden, .alwaysHidden:
            switch state {
            case .showSection:
                switch appState.settings.advanced.sectionDividerStyle {
                case .noDivider:
                    updateStatusItemVisibility(false)
                    button.appearsDisabled = true
                    button.isHighlighted = false

                    if appState.isDraggingMenuBarItem, appState.settings.advanced.showAllSectionsOnUserDrag {
                        // We still want a subtle marker between sections.
                        button.title = "|"
                    }
                case .chevron:
                    updateStatusItemVisibility(true)
                    button.appearsDisabled = false

                    if identifier != .visible {
                        button.image = ControlItemImage.builtin(.chevronSmall).nsImage(for: appState)
                    }
                }
            case .hideSection:
                updateStatusItemVisibility(true)
                button.appearsDisabled = true
                button.isHighlighted = false
            }
        }
    }

    /// Updates the visibility of the status item.
    ///
    /// The hidden and always-hidden control items must always be present in
    /// the menu bar, as we use their positions to determine the items in each
    /// section. Setting `statusItem.isVisible` to `false` completely removes
    /// the item. Instead, we toggle the width constraint on the item's content
    /// view, update the item's length, then adjust the content size of the
    /// item's window if needed.
    private func updateStatusItemVisibility(_ isVisible: Bool) {
        guard let appState, let statusItem, identifier != .visible else {
            return
        }

        if isVisible {
            constraint?.isActive = true
            statusItem.length = identifier.length(for: state)

            let shouldUseSpacers = (identifier == .hidden || identifier == .alwaysHidden) && state == .hideSection
            updateSpacerItems(forHiddenState: shouldUseSpacers)
        } else {
            updateSpacerItems(forHiddenState: false)
            let showOnDrag = appState.settings.advanced.showAllSectionsOnUserDrag
            let isDragging = appState.isDraggingMenuBarItem

            let shouldShow = showOnDrag && isDragging

            constraint?.isActive = false
            statusItem.length = shouldShow ? 3 : 0

            if let window {
                let size = withMutableCopy(of: window.frame.size) { $0.width = shouldShow ? 3 : 1 }
                window.setContentSize(size)
            }
        }
    }

    /// Spacer items not needed with expanded=1.
    private func updateSpacerItems(forHiddenState _: Bool) {
        removeSpacerItems()
    }

    private func removeSpacerItems() {
        for item in spacerItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        spacerItems.removeAll()
    }

    /// Adds the control item to the menu bar.
    private func addToMenuBar() {
        guard identifier != .visible, let statusItem, !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
    }

    /// Removes the control item from the menu bar.
    private func removeFromMenuBar() {
        guard identifier != .visible, let statusItem, isAddedToMenuBar else {
            return
        }
        let autosaveName = statusItem.autosaveName as String
        let isSectionDivider = (identifier == .hidden || identifier == .alwaysHidden)
        let cached = ControlItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        if !isSectionDivider {
            ControlItemDefaults[.preferredPosition, autosaveName] = cached
        }
    }

    /// Performs the control item's action.
    @objc private func performAction() {
        // The visible control item's clicks are handled by the overlay panel.
        guard identifier != .visible else { return }
        guard
            let menuBarManager = appState?.menuBarManager,
            let event = NSApp.currentEvent
        else {
            return
        }

        switch event.type {
        case .leftMouseDown:
            // Capture modifier flags from the event to ensure we have the state
            // at the time of the click, not when the Task executes.
            let modifierFlags = event.modifierFlags

            // Running this from a Task seems to improve the visual
            // responsiveness of the status item's button.
            Task {
                if
                    event.clickCount > 1,
                    identifier == .visible,
                    let alwaysHidden = menuBarManager.section(withName: .alwaysHidden),
                    alwaysHidden.isEnabled
                {
                    alwaysHidden.show()
                    return
                }

                if modifierFlags == .control {
                    showMenu()
                    return
                }

                if
                    modifierFlags == .option,
                    let section = menuBarManager.section(withName: .alwaysHidden),
                    section.isEnabled
                {
                    section.toggle()
                    return
                }

                if
                    let section = menuBarManager.section(withName: sectionName),
                    section.isEnabled
                {
                    section.toggle()
                }
            }
        case .rightMouseUp:
            showMenu()
        default:
            return
        }
    }

    /// Creates a menu to show under the control item.
    private func createMenu(with appState: AppState) -> NSMenu {
        func hotkey(withAction action: HotkeyAction) -> Hotkey? {
            appState.settings.hotkeys.hotkey(withAction: action)
        }

        let menu = NSMenu(title: Bundle.main.displayName)

        let settingsItem = NSMenuItem(
            title: String(localized: "\(Constants.displayName) Settings…"),
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let searchItem = NSMenuItem(
            title: String(localized: "Search Menu Bar Items"),
            action: #selector(showSearchPanel),
            keyEquivalent: ""
        )
        searchItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        if
            let hotkey = hotkey(withAction: .searchMenuBarItems),
            let keyCombination = hotkey.keyCombination
        {
            searchItem.keyEquivalent = keyCombination.key.keyEquivalent
            searchItem.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
        }
        searchItem.target = self
        menu.addItem(searchItem)

        menu.addItem(.separator())

        // Add items to toggle the hidden and always-hidden sections.
        for name: MenuBarSection.Name in [.hidden, .alwaysHidden] {
            guard
                let section = appState.menuBarManager.section(withName: name),
                section.isEnabled
            else {
                continue
            }
            let sectionTitle: String
            let iconName: String
            switch (section.isHidden, name) {
            case (true, .hidden):
                sectionTitle = String(localized: "Show Hidden Section")
                iconName = "eye"
            case (false, .hidden):
                sectionTitle = String(localized: "Hide Hidden Section")
                iconName = "eye.slash"
            case (true, .alwaysHidden):
                sectionTitle = String(localized: "Show Always-Hidden Section")
                iconName = "eye"
            case (false, .alwaysHidden):
                sectionTitle = String(localized: "Hide Always-Hidden Section")
                iconName = "eye.slash"
            default:
                sectionTitle = String(localized: "\(section.isHidden ? "Show" : "Hide") \(name.displayString) Section")
                iconName = section.isHidden ? "eye" : "eye.slash"
            }
            let item = NSMenuItem(
                title: sectionTitle,
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: sectionTitle)
            if
                let hotkey = section.hotkey,
                let keyCombination = hotkey.keyCombination
            {
                item.keyEquivalent = keyCombination.key.keyEquivalent
                item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
            }
            item.target = self
            item.representedObject = section
            menu.addItem(item)
        }

        // Profiles submenu.
        let profileManager = appState.profileManager
        if !profileManager.profiles.isEmpty {
            menu.addItem(.separator())

            let profilesItem = NSMenuItem(
                title: String(localized: "Profiles"),
                action: nil,
                keyEquivalent: ""
            )
            profilesItem.image = NSImage(
                systemSymbolName: "person.crop.rectangle.stack",
                accessibilityDescription: "Profiles"
            )
            let profilesMenu = NSMenu()
            for meta in profileManager.profiles {
                let item = NSMenuItem(
                    title: meta.name,
                    action: #selector(applyProfileFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = meta.id
                if meta.id == profileManager.activeProfileID {
                    item.state = .on
                }
                profilesMenu.addItem(item)
            }
            profilesItem.submenu = profilesMenu
            menu.addItem(profilesItem)
        }

        menu.addItem(.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Check for Updates")
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit \(Constants.displayName)"),
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(quitItem)

        return menu
    }

    /// Shows the control item's menu.
    private func showMenu() {
        guard let appState, let statusItem else {
            return
        }
        let menu = createMenu(with: appState)
        statusItem.showMenu(menu)
    }

    /// Toggles the menu bar section associated with the given menu item.
    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        guard let section = menuItem.representedObject as? MenuBarSection else {
            return
        }
        section.toggle()
    }

    /// Opens the menu bar search panel.
    @objc private func showSearchPanel() {
        appState?.menuBarManager.searchPanel.show()
    }

    /// Applies the profile selected from the context menu.
    @objc private func applyProfileFromMenu(_ menuItem: NSMenuItem) {
        guard
            let profileID = menuItem.representedObject as? UUID,
            let appState,
            appState.profileManager.layoutTask == nil,
            profileID != appState.profileManager.activeProfileID
        else { return }
        let profileManager = appState.profileManager
        Task {
            guard let profile = try? profileManager.loadProfile(id: profileID) else { return }
            profileManager.activeProfileID = profileID
            profileManager.applyProfile(profile, to: appState)
        }
    }

    /// Opens the settings window and checks for app updates.
    @objc private func checkForUpdates() {
        guard let appState else {
            return
        }
        appState.updatesManager.checkForUpdates()
    }
}

// MARK: - ControlItemDefaults

/// Proxy getters and setters for a control item's stored
/// UserDefaults values.
enum ControlItemDefaults {
    /// Accesses the value associated with the specified key
    /// and autosave name.
    static subscript<Value>(key: Key<Value>, autosaveName: String) -> Value? {
        get {
            let stringKey = key.stringKey(for: autosaveName)
            return UserDefaults.standard.object(forKey: stringKey) as? Value
        }
        set {
            // Prevent saving preferred position for section divider chevrons
            if key.isPreferredPosition, isSectionDivider(autosaveName: autosaveName) {
                return
            }
            let stringKey = key.stringKey(for: autosaveName)
            return UserDefaults.standard.set(newValue, forKey: stringKey)
        }
    }

    /// Returns whether the given autosave name belongs to a section divider.
    static func isSectionDivider(autosaveName: String) -> Bool {
        autosaveName == ControlItem.Identifier.hidden.rawValue ||
            autosaveName == ControlItem.Identifier.alwaysHidden.rawValue
    }

    /// Migrates the given control item defaults key from an old
    /// autosave name to a new autosave name.
    static func migrate<Value>(key: Key<Value>, from oldAutosaveName: String, to newAutosaveName: String) {
        guard newAutosaveName != oldAutosaveName else {
            return
        }
        Self[key, newAutosaveName] = Self[key, oldAutosaveName]
        Self[key, oldAutosaveName] = nil
    }

    /// Performs some initial required setup work before the
    /// creation of a control item.
    fileprivate static func preflightSetup(for controlItem: ControlItem) {
        let autosaveName = controlItem.identifier.rawValue

        // Visible and hidden control items should be added before
        // existing items in the status bar.
        if ControlItemDefaults[.preferredPosition, autosaveName] == nil {
            switch controlItem.identifier {
            case .visible:
                ControlItemDefaults[.preferredPosition, autosaveName] = 0
            case .hidden:
                ControlItemDefaults[.preferredPosition, autosaveName] = 1
            case .alwaysHidden:
                break
            }
        }

        // Always reset section divider positions to defaults
        // to prevent issues when users move them around
        if isSectionDivider(autosaveName: autosaveName) {
            switch controlItem.identifier {
            case .hidden:
                ControlItemDefaults[.preferredPosition, autosaveName] = 1
            case .alwaysHidden:
                // Don't set a default position for always-hidden
                // It will be positioned dynamically by the system
                break
            case .visible:
                break
            }
        }

        // The control item should be visible by default. We change
        // this after finishing setup, if needed.
        if ControlItemDefaults[.visible, autosaveName] == nil {
            ControlItemDefaults[.visible, autosaveName] = true
        }
        if
            #available(macOS 26.0, *),
            ControlItemDefaults[.visibleCC, autosaveName] == nil
        {
            ControlItemDefaults[.visibleCC, autosaveName] = true
        }
    }

    /// Resets chevron section divider positions to their defaults.
    static func resetChevronPositions() {
        ControlItemDefaults[.preferredPosition, ControlItem.Identifier.hidden.rawValue] = 1
        // Always-hidden position is handled dynamically
    }
}

// MARK: - ControlItemDefaults.Key

extension ControlItemDefaults {
    /// Keys used to look up UserDefaults values for control items.
    struct Key<Value> {
        /// The raw value of the key.
        let rawValue: String

        /// Whether this key represents a preferred position.
        var isPreferredPosition: Bool {
            rawValue == "Preferred Position"
        }

        /// Returns the full string key for the given autosave name.
        func stringKey(for autosaveName: String) -> String {
            "NSStatusItem \(rawValue) \(autosaveName)"
        }
    }
}

// MARK: ControlItemDefaults.Key<CGFloat>

extension ControlItemDefaults.Key<CGFloat> {
    /// String key: "NSStatusItem Preferred Position autosaveName"
    static let preferredPosition = Self(rawValue: "Preferred Position")
}

// MARK: ControlItemDefaults.Key<Bool>

extension ControlItemDefaults.Key<Bool> {
    /// String key: "NSStatusItem Visible autosaveName"
    static let visible = Self(rawValue: "Visible")

    /// String key: "NSStatusItem VisibleCC autosaveName"
    static let visibleCC = Self(rawValue: "VisibleCC")
}

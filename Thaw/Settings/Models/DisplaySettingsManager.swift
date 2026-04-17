//
//  DisplaySettingsManager.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine

/// Manages per-display Ice Bar configuration.
///
/// Configurations are keyed by display UUID string (via `Bridging.getDisplayUUIDString(for:)`).
/// When a display has no explicit configuration, `DisplayIceBarConfiguration.defaultConfiguration`
/// is returned.
@MainActor
final class DisplaySettingsManager: ObservableObject {
    private let diagLog = DiagLog(category: "DisplaySettingsManager")

    /// Per-display configurations, keyed by display UUID string.
    @Published var configurations: [String: DisplayIceBarConfiguration] = [:]

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// JSON encoder for persistence.
    private let encoder = JSONEncoder()

    /// JSON decoder for persistence.
    private let decoder = JSONDecoder()

    /// Performs the initial setup of the manager.
    func performSetup(with _: AppState) {
        loadInitialState()
        configureCancellables()
    }

    // MARK: - Loading

    /// Loads saved configurations from Defaults.
    private func loadInitialState() {
        guard let data = Defaults.data(forKey: .displayIceBarConfigurations) else {
            return
        }
        do {
            configurations = try decoder.decode([String: DisplayIceBarConfiguration].self, from: data)
            diagLog.info("Loaded per-display configurations for \(configurations.count) display(s)")
        } catch {
            diagLog.error("Failed to decode per-display configurations: \(error)")
        }
    }

    // MARK: - Persistence

    /// Configures Combine sinks to persist configurations on change.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $configurations
            .dropFirst() // Skip the initial emission during setup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configs in
                guard let self else { return }
                do {
                    let data = try encoder.encode(configs)
                    Defaults.set(data, forKey: .displayIceBarConfigurations)
                } catch {
                    diagLog.error("Failed to encode per-display configurations: \(error)")
                }
            }
            .store(in: &c)

        // Listen for display connect/disconnect to log changes.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                diagLog.info("Screen parameters changed — \(NSScreen.screens.count) screen(s) connected")
            }
            .store(in: &c)

        // Listen for external per-display settings changes via Settings URI
        NotificationCenter.default
            .publisher(for: .perDisplaySettingsDidChangeViaURI)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleExternalPerDisplaySettingsChange(notification)
            }
            .store(in: &c)

        cancellables = c
    }

    /// Handles per-display settings changed externally via Settings URI scheme.
    private func handleExternalPerDisplaySettingsChange(_ notification: Notification) {
        guard let key = notification.userInfo?["key"] as? String,
              let scopeRaw = notification.userInfo?["scope"] as? String
        else {
            return
        }

        // Parse scope - it might be a simple scope or "specific:UUID"
        let (scope, specificUUID) = parseScope(from: scopeRaw)

        diagLog.debug("DisplaySettingsManager: Received external change for \(key) with scope \(scope)\(specificUUID.map { " (UUID: \($0))" } ?? "")")

        switch key {
        case "useIceBar":
            if notification.userInfo?["toggle"] as? Bool == true {
                // Toggle operation
                if let uuid = specificUUID {
                    toggleUseIceBar(forDisplayUUID: uuid)
                } else {
                    toggleIceBarForActiveDisplay()
                }
            } else if let value = notification.userInfo?["value"] as? Bool {
                // Set operation
                if let uuid = specificUUID {
                    setUseIceBar(value, forDisplayUUID: uuid)
                } else {
                    setUseIceBar(value, forActiveDisplay: true)
                }
            }

        case "iceBarLocation":
            if let rawValueString = notification.userInfo?["stringValue"] as? String,
               let rawValue = Int(rawValueString),
               let location = IceBarLocation(rawValue: rawValue)
            {
                if let uuid = specificUUID {
                    setIceBarLocation(location, forDisplayUUID: uuid)
                } else {
                    setIceBarLocation(location, scope: scope)
                }
            }

        case "alwaysShowHiddenItems":
            if notification.userInfo?["toggle"] as? Bool == true {
                if let uuid = specificUUID {
                    toggleAlwaysShowHiddenItems(forDisplayUUID: uuid)
                } else {
                    toggleAlwaysShowHiddenItems(scope: scope)
                }
            } else if let value = notification.userInfo?["value"] as? Bool {
                if let uuid = specificUUID {
                    setAlwaysShowHiddenItems(value, forDisplayUUID: uuid)
                } else {
                    setAlwaysShowHiddenItems(value, scope: scope)
                }
            }

        default:
            break
        }
    }

    /// Parses scope string into scope enum and optional specific UUID.
    /// Format: "active", "allEnabled", "allNonIceBar", or "specific:UUID"
    private func parseScope(from scopeRaw: String) -> (SettingsURIHandler.PerDisplayScope, String?) {
        if scopeRaw.hasPrefix("specific:") {
            let uuid = String(scopeRaw.dropFirst("specific:".count))
            return (.activeDisplay, uuid) // Use activeDisplay as placeholder, UUID determines actual target
        }
        switch scopeRaw {
        case "active": return (.activeDisplay, nil)
        case "allEnabled": return (.allEnabledDisplays, nil)
        case "allNonIceBar": return (.allNonIceBarDisplays, nil)
        default: return (.activeDisplay, nil)
        }
    }

    /// Sets useIceBar for the active display.
    private func setUseIceBar(_ value: Bool, forActiveDisplay: Bool) {
        if forActiveDisplay {
            guard let uuid = Bridging.getActiveMenuBarDisplayUUID() else {
                diagLog.warning("Cannot set useIceBar — no active menu bar display UUID")
                return
            }
            updateConfiguration(forDisplayUUID: uuid) { config in
                config.withUseIceBar(value)
            }
        }
    }

    /// Sets useIceBar for a specific display UUID.
    private func setUseIceBar(_ value: Bool, forDisplayUUID uuid: String) {
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withUseIceBar(value)
        }
    }

    /// Toggles useIceBar for a specific display UUID.
    private func toggleUseIceBar(forDisplayUUID uuid: String) {
        let current = configurations[uuid] ?? .defaultConfiguration
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withUseIceBar(!current.useIceBar)
        }
    }

    /// Sets iceBarLocation for displays based on scope.
    private func setIceBarLocation(_ location: IceBarLocation, scope: SettingsURIHandler.PerDisplayScope) {
        switch scope {
        case .allEnabledDisplays:
            // Update all displays that have IceBar enabled
            for screen in NSScreen.screens {
                guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else { continue }
                let config = configurations[uuid] ?? .defaultConfiguration
                if config.useIceBar {
                    updateConfiguration(forDisplayUUID: uuid) { $0.withIceBarLocation(location) }
                }
            }
        default:
            diagLog.debug("setIceBarLocation not implemented for scope \(scope)")
        }
    }

    /// Sets iceBarLocation for a specific display UUID.
    private func setIceBarLocation(_ location: IceBarLocation, forDisplayUUID uuid: String) {
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withIceBarLocation(location)
        }
    }

    /// Sets alwaysShowHiddenItems for displays based on scope.
    private func setAlwaysShowHiddenItems(_ value: Bool, scope: SettingsURIHandler.PerDisplayScope) {
        switch scope {
        case .allNonIceBarDisplays:
            // Update all displays that do NOT have IceBar enabled
            for screen in NSScreen.screens {
                guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else { continue }
                let config = configurations[uuid] ?? .defaultConfiguration
                if !config.useIceBar {
                    updateConfiguration(forDisplayUUID: uuid) { $0.withAlwaysShowHiddenItems(value) }
                }
            }
        default:
            diagLog.debug("setAlwaysShowHiddenItems not implemented for scope \(scope)")
        }
    }

    /// Toggles alwaysShowHiddenItems for displays based on scope.
    private func toggleAlwaysShowHiddenItems(scope: SettingsURIHandler.PerDisplayScope) {
        switch scope {
        case .allNonIceBarDisplays:
            // Toggle on all displays that do NOT have IceBar enabled
            for screen in NSScreen.screens {
                guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else { continue }
                let config = configurations[uuid] ?? .defaultConfiguration
                if !config.useIceBar {
                    updateConfiguration(forDisplayUUID: uuid) { $0.withAlwaysShowHiddenItems(!$0.alwaysShowHiddenItems) }
                }
            }
        default:
            diagLog.debug("toggleAlwaysShowHiddenItems not implemented for scope \(scope)")
        }
    }

    /// Sets alwaysShowHiddenItems for a specific display UUID.
    private func setAlwaysShowHiddenItems(_ value: Bool, forDisplayUUID uuid: String) {
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withAlwaysShowHiddenItems(value)
        }
    }

    /// Toggles alwaysShowHiddenItems for a specific display UUID.
    private func toggleAlwaysShowHiddenItems(forDisplayUUID uuid: String) {
        let current = configurations[uuid] ?? .defaultConfiguration
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withAlwaysShowHiddenItems(!current.alwaysShowHiddenItems)
        }
    }

    // MARK: - Lookup

    /// Returns the configuration for a given display ID.
    func configuration(for displayID: CGDirectDisplayID) -> DisplayIceBarConfiguration {
        guard let uuid = Bridging.getDisplayUUIDString(for: displayID) else {
            return .defaultConfiguration
        }
        return configurations[uuid] ?? .defaultConfiguration
    }

    /// Returns the configuration for the display with the active menu bar.
    func configurationForActiveDisplay() -> DisplayIceBarConfiguration {
        guard let displayID = Bridging.getActiveMenuBarDisplayID() else {
            return .defaultConfiguration
        }
        return configuration(for: displayID)
    }

    /// Whether the Ice Bar is enabled for the given display.
    func useIceBar(for displayID: CGDirectDisplayID) -> Bool {
        configuration(for: displayID).useIceBar
    }

    /// The Ice Bar location for the given display.
    func iceBarLocation(for displayID: CGDirectDisplayID) -> IceBarLocation {
        configuration(for: displayID).iceBarLocation
    }

    /// Whether hidden items should always be shown for the given display.
    func alwaysShowHiddenItems(for displayID: CGDirectDisplayID) -> Bool {
        configuration(for: displayID).alwaysShowHiddenItems
    }

    /// Whether any connected display has the Ice Bar enabled.
    var isIceBarEnabledOnAnyDisplay: Bool {
        configurations.values.contains { $0.useIceBar }
    }

    /// Whether any connected display has "Always show hidden items" enabled.
    var isAlwaysShowEnabledOnAnyDisplay: Bool {
        configurations.values.contains { $0.alwaysShowHiddenItems }
    }

    // MARK: - Mutation (Immutable Pattern)

    /// Updates the configuration for a display by applying a transform,
    /// producing a new dictionary (immutable pattern).
    func updateConfiguration(
        forDisplayUUID uuid: String,
        transform: (DisplayIceBarConfiguration) -> DisplayIceBarConfiguration
    ) {
        let current = configurations[uuid] ?? .defaultConfiguration
        let updated = transform(current)
        var newConfigurations = configurations
        newConfigurations[uuid] = updated
        configurations = newConfigurations
    }

    /// Toggles the Ice Bar for the display with the active menu bar.
    func toggleIceBarForActiveDisplay() {
        guard let uuid = Bridging.getActiveMenuBarDisplayUUID() else {
            diagLog.warning("Cannot toggle Ice Bar — no active menu bar display UUID")
            return
        }
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withUseIceBar(!config.useIceBar)
        }
    }

    // MARK: - Display Info

    /// Information about a connected display for use in the settings UI.
    struct DisplayInfo: Identifiable {
        let id: String // UUID string
        let displayID: CGDirectDisplayID
        let name: String
        let hasNotch: Bool
    }

    /// Returns info about all currently connected displays.
    func connectedDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else {
                return nil
            }
            return DisplayInfo(
                id: uuid,
                displayID: screen.displayID,
                name: screen.localizedName,
                hasNotch: screen.hasNotch
            )
        }
    }
}

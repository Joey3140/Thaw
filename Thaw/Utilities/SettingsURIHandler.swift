//
//  SettingsURIHandler.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import Foundation

/// Handles settings manipulation via thaw:// URLs with whitelist-based security.
@MainActor
enum SettingsURIHandler {
    private static let diagLog = DiagLog(category: "SettingsURIHandler")

    /// Tier 1: Safe boolean toggles that can be manipulated via URI
    static let supportedBooleanKeys: [String] = [
        "autoRehide",
        "showOnClick",
        "showOnDoubleClick",
        "showOnHover",
        "showOnScroll",
        "useIceBar",
        "useIceBarOnlyOnNotchedDisplay",
        "hideApplicationMenus",
        "enableAlwaysHiddenSection",
        "useOptionClickToShowAlwaysHiddenSection",
        "enableSecondaryContextMenu",
        "showAllSectionsOnUserDrag",
        "showMenuBarTooltips",
        "enableDiagnosticLogging",
        "customIceIconIsTemplate",
        "showIceIcon",
        "iceBarLocationOnHotkey",
        "useLCSSortingOnNotchedDisplays",
    ]

    /// Double/numeric settings with ranges
    static let doubleKeys: [String] = [
        "rehideInterval",
        "showOnHoverDelay",
        "tooltipDelay",
        "iconRefreshInterval",
    ]

    /// Enum settings with string values
    static let enumKeys: [String] = [
        "rehideStrategy",
    ]

    /// Per-display settings keys (stored in DisplaySettingsManager, not Defaults)
    static let perDisplayKeys: [String] = [
        "useIceBar",
        "iceBarLocation",
        "alwaysShowHiddenItems",
    ]

    /// Mapping of URI key names to Defaults.Key enum cases
    private static let keyMapping: [String: Defaults.Key] = [
        "autoRehide": .autoRehide,
        "showOnClick": .showOnClick,
        "showOnDoubleClick": .showOnDoubleClick,
        "showOnHover": .showOnHover,
        "showOnScroll": .showOnScroll,
        "useIceBarOnlyOnNotchedDisplay": .useIceBarOnlyOnNotchedDisplay,
        "hideApplicationMenus": .hideApplicationMenus,
        "enableAlwaysHiddenSection": .enableAlwaysHiddenSection,
        "useOptionClickToShowAlwaysHiddenSection": .useOptionClickToShowAlwaysHiddenSection,
        "enableSecondaryContextMenu": .enableSecondaryContextMenu,
        "showAllSectionsOnUserDrag": .showAllSectionsOnUserDrag,
        "showMenuBarTooltips": .showMenuBarTooltips,
        "enableDiagnosticLogging": .enableDiagnosticLogging,
        "customIceIconIsTemplate": .customIceIconIsTemplate,
        "showIceIcon": .showIceIcon,
        "iceBarLocationOnHotkey": .iceBarLocationOnHotkey,
        "useLCSSortingOnNotchedDisplays": .useLCSSortingOnNotchedDisplays,
        "rehideInterval": .rehideInterval,
        "showOnHoverDelay": .showOnHoverDelay,
        "tooltipDelay": .tooltipDelay,
        "iconRefreshInterval": .iconRefreshInterval,
        "rehideStrategy": .rehideStrategy,
    ]

    /// Valid ranges for double settings (min, max, default)
    private static let doubleRanges: [String: (min: Double, max: Double)] = [
        "rehideInterval": (1, 300),
        "showOnHoverDelay": (0, 5),
        "tooltipDelay": (0, 5),
        "iconRefreshInterval": (0.1, 5),
    ]

    // MARK: - Security

    /// Checks if the sender is in the whitelist.
    static func isWhitelisted(bundleIdentifier: String?) -> Bool {
        guard let bundleId = bundleIdentifier, !bundleId.isEmpty else {
            diagLog.warning("Settings URI: No sender bundle ID provided")
            return false
        }

        let whitelist = Defaults.stringArray(forKey: .settingsURIWhitelist) ?? []
        let isAllowed = whitelist.contains(bundleId)

        if isAllowed {
            diagLog.debug("Settings URI: Authorized request from \(bundleId)")
        } else {
            diagLog.debug("Settings URI: Unauthorized request from \(bundleId)")
        }

        return isAllowed
    }

    /// Shows NSAlert confirmation dialog for first-time authorization.
    /// Returns true if user approves, false otherwise.
    static func promptForAuthorization(bundleId: String) -> Bool {
        let appName = getAppName(for: bundleId) ?? bundleId

        let alert = NSAlert()
        alert.messageText = String(localized: "Allow \"\(appName)\" to control Thaw settings?")
        alert.informativeText = String(
            localized: """
            "\(appName)" (\(bundleId)) wants to modify Thaw settings via URL scheme.

            If allowed, this app will be able to:
            • Toggle hidden section visibility
            • Change auto-rehide behavior
            • Modify other boolean settings

            This permission is permanent until manually removed in Settings > Automation.
            """
        )

        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Deny"))

        let response = alert.runModal()
        let approved = response == .alertFirstButtonReturn

        if approved {
            diagLog.info("Settings URI: User authorized \(bundleId)")
            addToWhitelist(bundleId: bundleId)
        } else {
            diagLog.info("Settings URI: User denied \(bundleId)")
        }

        return approved
    }

    /// Adds a bundle ID to the whitelist.
    static func addToWhitelist(bundleId: String) {
        var whitelist = Defaults.stringArray(forKey: .settingsURIWhitelist) ?? []
        guard !whitelist.contains(bundleId) else { return }

        whitelist.append(bundleId)
        Defaults.set(whitelist, forKey: .settingsURIWhitelist)
        diagLog.info("Settings URI: Added \(bundleId) to whitelist")
    }

    /// Removes a bundle ID from the whitelist.
    static func removeFromWhitelist(bundleId: String) {
        var whitelist = Defaults.stringArray(forKey: .settingsURIWhitelist) ?? []
        whitelist.removeAll { $0 == bundleId }
        Defaults.set(whitelist, forKey: .settingsURIWhitelist)
        diagLog.info("Settings URI: Removed \(bundleId) from whitelist")
    }

    /// Gets the display name for a bundle ID.
    static func getAppName(for bundleId: String) -> String? {
        // Try to find running app
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            return app.localizedName
        }

        // Try to get from bundle path
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            if let bundle = Bundle(url: url) {
                return bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            }
        }

        return nil
    }

    /// Gets the icon for a bundle ID.
    static func getAppIcon(for bundleId: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    // MARK: - Validation

    /// Checks if a settings key is supported for URI manipulation.
    static func isValidSettingsKey(_ key: String) -> Bool {
        return supportedBooleanKeys.contains(key)
            || doubleKeys.contains(key)
            || enumKeys.contains(key)
    }

    /// Parses a boolean value from string.
    static func parseBool(_ value: String) -> Bool? {
        let lowercased = value.lowercased()
        if lowercased == "true" || lowercased == "1" || lowercased == "yes" {
            return true
        } else if lowercased == "false" || lowercased == "0" || lowercased == "no" {
            return false
        }
        return nil
    }

    /// Parses a double value from string.
    static func parseDouble(_ value: String) -> Double? {
        return Double(value)
    }

    // MARK: - Execution

    /// Handles thaw://set?key=X&value=Y&type=bool URL.
    /// Returns true if setting was changed successfully.
    static func handleSet(key: String, value: String, sender: String?, displayUUID: String? = nil) -> Bool {
        diagLog.debug("Settings URI: set request - key=\(key), value=\(value), sender=\(sender ?? "unknown"), display=\(displayUUID ?? "none")")

        // Validate key
        guard isValidSettingsKey(key) else {
            diagLog.warning("Settings URI: Invalid key '\(key)'")
            return false
        }

        // Check if this is a per-display setting
        if perDisplayKeys.contains(key) {
            return handlePerDisplaySet(key: key, value: value, displayUUID: displayUUID)
        }

        // Route to appropriate handler based on key type
        if doubleKeys.contains(key) {
            return handleDoubleSet(key: key, value: value)
        } else if enumKeys.contains(key) {
            return handleEnumSet(key: key, value: value)
        }

        // Parse boolean value
        guard let boolValue = parseBool(value) else {
            diagLog.warning("Settings URI: Invalid boolean value '\(value)'")
            return false
        }

        // Get the Defaults.Key
        guard let defaultsKey = keyMapping[key] else {
            diagLog.error("Settings URI: No mapping for key '\(key)'")
            return false
        }

        // Apply the setting
        Defaults.set(boolValue, forKey: defaultsKey)

        // Notify settings models that a value changed externally
        postSettingsDidChangeNotification(key: key, value: boolValue)

        diagLog.info("Settings URI: Set \(key) = \(boolValue)")

        return true
    }

    /// Handles setting a double/numeric value with range validation.
    private static func handleDoubleSet(key: String, value: String) -> Bool {
        guard let doubleValue = parseDouble(value) else {
            diagLog.warning("Settings URI: Invalid double value '\(value)' for \(key)")
            return false
        }

        // Validate and clamp to range
        let (minVal, maxVal) = doubleRanges[key] ?? (0, Double.greatestFiniteMagnitude)
        let clampedValue = Swift.max(minVal, Swift.min(doubleValue, maxVal))

        if clampedValue != doubleValue {
            diagLog.debug("Settings URI: Clamped \(key) from \(doubleValue) to \(clampedValue) (range: \(minVal)-\(maxVal))")
        }

        // Get the Defaults.Key
        guard let defaultsKey = keyMapping[key] else {
            diagLog.error("Settings URI: No mapping for key '\(key)'")
            return false
        }

        // Apply the setting
        Defaults.set(clampedValue, forKey: defaultsKey)

        // Notify settings models that a value changed externally
        postSettingsDidChangeNotification(key: key, doubleValue: clampedValue)

        diagLog.info("Settings URI: Set \(key) = \(clampedValue)")

        return true
    }

    /// Handles setting an enum value.
    private static func handleEnumSet(key: String, value: String) -> Bool {
        switch key {
        case "rehideStrategy":
            guard let strategy = RehideStrategy.fromString(value) else {
                diagLog.warning("Settings URI: Invalid rehideStrategy value '\(value)'. Valid: smart (0), timed (1), focusedApp (2)")
                return false
            }

            guard let defaultsKey = keyMapping[key] else {
                diagLog.error("Settings URI: No mapping for key '\(key)'")
                return false
            }

            Defaults.set(strategy.rawValue, forKey: defaultsKey)
            postSettingsDidChangeNotification(key: key, rawEnumValue: strategy.rawValue)
            diagLog.info("Settings URI: Set \(key) = \(strategy) (\(strategy.rawValue))")
            return true

        default:
            return false
        }
    }

    /// Handles setting a per-display configuration value.
    /// useIceBar: affects active display only (or specific display if UUID provided)
    /// iceBarLocation, alwaysShowHiddenItems: affects all displays with IceBar enabled (or specific display if UUID provided)
    private static func handlePerDisplaySet(key: String, value: String, displayUUID: String?) -> Bool {
        // If specific display UUID provided, use that
        if let uuid = displayUUID, !uuid.isEmpty {
            return handlePerDisplaySetForSpecificDisplay(key: key, value: value, displayUUID: uuid)
        }

        // Otherwise use default scope behavior
        switch key {
        case "useIceBar":
            guard let boolValue = parseBool(value) else {
                diagLog.warning("Settings URI: Invalid boolean value '\(value)' for useIceBar")
                return false
            }
            // Post notification for DisplaySettingsManager to handle active display
            postPerDisplaySettingsDidChangeNotification(key: key, value: boolValue, scope: .activeDisplay)
            diagLog.info("Settings URI: Set useIceBar = \(boolValue) on active display")
            return true

        case "iceBarLocation":
            // Parse IceBarLocation from string value
            guard let location = IceBarLocation.fromString(value) else {
                diagLog.warning("Settings URI: Invalid iceBarLocation value '\(value)'. Valid: dynamic, mousePointer, iceIcon (or 0, 1, 2)")
                return false
            }
            // Post notification for DisplaySettingsManager to handle all enabled displays
            // Use rawValue string for consistency
            postPerDisplaySettingsDidChangeNotification(key: key, stringValue: String(location.rawValue), scope: .allEnabledDisplays)
            diagLog.info("Settings URI: Set iceBarLocation = \(location) on all enabled displays")
            return true

        case "alwaysShowHiddenItems":
            guard let boolValue = parseBool(value) else {
                diagLog.warning("Settings URI: Invalid boolean value '\(value)' for alwaysShowHiddenItems")
                return false
            }
            // Post notification for DisplaySettingsManager to handle all displays without IceBar
            postPerDisplaySettingsDidChangeNotification(key: key, value: boolValue, scope: .allNonIceBarDisplays)
            diagLog.info("Settings URI: Set alwaysShowHiddenItems = \(boolValue) on all non-IceBar displays")
            return true

        default:
            return false
        }
    }

    /// Handles setting a per-display configuration value for a specific display UUID.
    private static func handlePerDisplaySetForSpecificDisplay(key: String, value: String, displayUUID: String) -> Bool {
        // Validate UUID format (basic check: should contain dashes and not be empty)
        guard displayUUID.contains("-") && !displayUUID.isEmpty else {
            diagLog.warning("Settings URI: Invalid display UUID format '\(displayUUID)'")
            return false
        }

        switch key {
        case "useIceBar":
            guard let boolValue = parseBool(value) else {
                diagLog.warning("Settings URI: Invalid boolean value '\(value)' for useIceBar")
                return false
            }
            // Post notification for specific display
            postPerDisplaySettingsDidChangeNotification(key: key, value: boolValue, scope: .specificDisplay(uuid: displayUUID))
            diagLog.info("Settings URI: Set useIceBar = \(boolValue) on display \(displayUUID)")
            return true

        case "iceBarLocation":
            // Parse IceBarLocation from string value
            guard let location = IceBarLocation.fromString(value) else {
                diagLog.warning("Settings URI: Invalid iceBarLocation value '\(value)'. Valid: dynamic, mousePointer, iceIcon (or 0, 1, 2)")
                return false
            }
            // Post notification for specific display
            postPerDisplaySettingsDidChangeNotification(key: key, stringValue: String(location.rawValue), scope: .specificDisplay(uuid: displayUUID))
            diagLog.info("Settings URI: Set iceBarLocation = \(location) on display \(displayUUID)")
            return true

        case "alwaysShowHiddenItems":
            guard let boolValue = parseBool(value) else {
                diagLog.warning("Settings URI: Invalid boolean value '\(value)' for alwaysShowHiddenItems")
                return false
            }
            // Post notification for specific display
            postPerDisplaySettingsDidChangeNotification(key: key, value: boolValue, scope: .specificDisplay(uuid: displayUUID))
            diagLog.info("Settings URI: Set alwaysShowHiddenItems = \(boolValue) on display \(displayUUID)")
            return true

        default:
            return false
        }
    }

    /// Handles thaw://toggle?key=X URL.
    /// Returns true if setting was toggled successfully.
    static func handleToggle(key: String, sender: String?, displayUUID: String? = nil) -> Bool {
        diagLog.debug("Settings URI: toggle request - key=\(key), sender=\(sender ?? "unknown"), display=\(displayUUID ?? "none")")

        // Validate key
        guard isValidSettingsKey(key) else {
            diagLog.warning("Settings URI: Invalid key '\(key)'")
            return false
        }

        // Check if this is a per-display setting
        if perDisplayKeys.contains(key) {
            return handlePerDisplayToggle(key: key, displayUUID: displayUUID)
        }

        // Get the Defaults.Key
        guard let defaultsKey = keyMapping[key] else {
            diagLog.error("Settings URI: No mapping for key '\(key)'")
            return false
        }

        // Get current value and toggle
        let currentValue = Defaults.bool(forKey: defaultsKey)
        let newValue = !currentValue

        // Apply the setting
        Defaults.set(newValue, forKey: defaultsKey)

        // Notify settings models that a value changed externally
        postSettingsDidChangeNotification(key: key, value: newValue)

        diagLog.info("Settings URI: Toggled \(key) from \(currentValue) to \(newValue)")

        return true
    }

    /// Handles toggling a per-display configuration value.
    /// Currently only supports useIceBar and alwaysShowHiddenItems.
    private static func handlePerDisplayToggle(key: String, displayUUID: String?) -> Bool {
        // If specific display UUID provided, use that
        if let uuid = displayUUID, !uuid.isEmpty {
            // Validate UUID format
            guard uuid.contains("-") && !uuid.isEmpty else {
                diagLog.warning("Settings URI: Invalid display UUID format '\(uuid)'")
                return false
            }

            switch key {
            case "useIceBar":
                // Post notification for DisplaySettingsManager to toggle specific display
                postPerDisplaySettingsDidChangeNotification(key: key, toggle: true, scope: .specificDisplay(uuid: uuid))
                diagLog.info("Settings URI: Toggled useIceBar on display \(uuid)")
                return true

            case "alwaysShowHiddenItems":
                // Post notification for DisplaySettingsManager to toggle specific display
                postPerDisplaySettingsDidChangeNotification(key: key, toggle: true, scope: .specificDisplay(uuid: uuid))
                diagLog.info("Settings URI: Toggled alwaysShowHiddenItems on display \(uuid)")
                return true

            default:
                // iceBarLocation doesn't support toggle
                diagLog.warning("Settings URI: Toggle not supported for '\(key)'")
                return false
            }
        }

        // Default behavior without UUID
        switch key {
        case "useIceBar":
            // Post notification for DisplaySettingsManager to toggle active display
            postPerDisplaySettingsDidChangeNotification(key: key, toggle: true, scope: .activeDisplay)
            diagLog.info("Settings URI: Toggled useIceBar on active display")
            return true

        case "alwaysShowHiddenItems":
            // Post notification for DisplaySettingsManager to toggle on all non-IceBar displays
            postPerDisplaySettingsDidChangeNotification(key: key, toggle: true, scope: .allNonIceBarDisplays)
            diagLog.info("Settings URI: Toggled alwaysShowHiddenItems on all non-IceBar displays")
            return true

        default:
            // iceBarLocation doesn't support toggle
            diagLog.warning("Settings URI: Toggle not supported for '\(key)'")
            return false
        }
    }

    /// Posts a notification that a setting was changed externally via Settings URI.
    private static func postSettingsDidChangeNotification(key: String, value: Bool) {
        NotificationCenter.default.post(
            name: .settingsDidChangeViaURI,
            object: nil,
            userInfo: [
                "key": key,
                "value": value,
            ]
        )
    }

    /// Posts a notification for double value settings.
    private static func postSettingsDidChangeNotification(key: String, doubleValue: Double) {
        NotificationCenter.default.post(
            name: .settingsDidChangeViaURI,
            object: nil,
            userInfo: [
                "key": key,
                "doubleValue": doubleValue,
            ]
        )
    }

    /// Posts a notification for enum value settings.
    private static func postSettingsDidChangeNotification(key: String, rawEnumValue: Int) {
        NotificationCenter.default.post(
            name: .settingsDidChangeViaURI,
            object: nil,
            userInfo: [
                "key": key,
                "rawEnumValue": rawEnumValue,
            ]
        )
    }

    /// Posts a notification for per-display settings changes.
    private static func postPerDisplaySettingsDidChangeNotification(
        key: String,
        value: Bool? = nil,
        stringValue: String? = nil,
        toggle: Bool = false,
        scope: PerDisplayScope
    ) {
        var userInfo: [String: Any] = [
            "key": key,
            "scope": scope.rawValue,
        ]
        if let value = value {
            userInfo["value"] = value
        }
        if let stringValue = stringValue {
            userInfo["stringValue"] = stringValue
        }
        if toggle {
            userInfo["toggle"] = true
        }

        NotificationCenter.default.post(
            name: .perDisplaySettingsDidChangeViaURI,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Scope for per-display setting application.
    enum PerDisplayScope {
        case activeDisplay
        case allEnabledDisplays
        case allNonIceBarDisplays
        case specificDisplay(uuid: String)

        /// String representation for notification userInfo
        var rawValue: String {
            switch self {
            case .activeDisplay: return "active"
            case .allEnabledDisplays: return "allEnabled"
            case .allNonIceBarDisplays: return "allNonIceBar"
            case let .specificDisplay(uuid): return "specific:\(uuid)"
            }
        }

        /// Extract UUID if this is a specific display scope
        var specificUUID: String? {
            switch self {
            case let .specificDisplay(uuid): return uuid
            default: return nil
            }
        }
    }

    /// Returns the current whitelist as an array of bundle IDs.
    static func getWhitelist() -> [String] {
        return Defaults.stringArray(forKey: .settingsURIWhitelist) ?? []
    }

    /// Checks if Settings URI feature is enabled.
    static func isEnabled() -> Bool {
        return Defaults.bool(forKey: .settingsURIEnabled)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a setting is changed externally via Settings URI scheme.
    static let settingsDidChangeViaURI = Notification.Name("com.stonerl.Thaw.settingsDidChangeViaURI")

    /// Posted when a per-display setting is changed externally via Settings URI scheme.
    static let perDisplaySettingsDidChangeViaURI = Notification.Name("com.stonerl.Thaw.perDisplaySettingsDidChangeViaURI")
}

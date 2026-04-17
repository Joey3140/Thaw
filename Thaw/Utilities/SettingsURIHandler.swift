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
    ]

    /// Mapping of URI key names to Defaults.Key enum cases
    private static let keyMapping: [String: Defaults.Key] = [
        "autoRehide": .autoRehide,
        "showOnClick": .showOnClick,
        "showOnDoubleClick": .showOnDoubleClick,
        "showOnHover": .showOnHover,
        "showOnScroll": .showOnScroll,
        "useIceBar": .useIceBar,
        "useIceBarOnlyOnNotchedDisplay": .useIceBarOnlyOnNotchedDisplay,
        "hideApplicationMenus": .hideApplicationMenus,
        "enableAlwaysHiddenSection": .enableAlwaysHiddenSection,
        "useOptionClickToShowAlwaysHiddenSection": .useOptionClickToShowAlwaysHiddenSection,
        "enableSecondaryContextMenu": .enableSecondaryContextMenu,
        "showAllSectionsOnUserDrag": .showAllSectionsOnUserDrag,
        "showMenuBarTooltips": .showMenuBarTooltips,
        "enableDiagnosticLogging": .enableDiagnosticLogging,
        "customIceIconIsTemplate": .customIceIconIsTemplate,
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

    // MARK: - Execution

    /// Handles thaw://set?key=X&value=Y&type=bool URL.
    /// Returns true if setting was changed successfully.
    static func handleSet(key: String, value: String, sender: String?) -> Bool {
        diagLog.debug("Settings URI: set request - key=\(key), value=\(value), sender=\(sender ?? "unknown")")

        // Validate key
        guard isValidSettingsKey(key) else {
            diagLog.warning("Settings URI: Invalid key '\(key)'")
            return false
        }

        // Parse value
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

    /// Handles thaw://toggle?key=X URL.
    /// Returns true if setting was toggled successfully.
    static func handleToggle(key: String, sender: String?) -> Bool {
        diagLog.debug("Settings URI: toggle request - key=\(key), sender=\(sender ?? "unknown")")

        // Validate key
        guard isValidSettingsKey(key) else {
            diagLog.warning("Settings URI: Invalid key '\(key)'")
            return false
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
}

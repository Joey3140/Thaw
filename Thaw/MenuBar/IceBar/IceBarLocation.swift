//
//  IceBarLocation.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// Locations where the Ice Bar can appear.
enum IceBarLocation: Int, CaseIterable, Codable, Identifiable {
    /// The Ice Bar will appear in different locations based on context.
    case dynamic = 0

    /// The Ice Bar will appear centered below the mouse pointer.
    case mousePointer = 1

    /// The Ice Bar will appear centered below the Ice icon.
    case iceIcon = 2

    var id: Int {
        rawValue
    }

    /// Localized string key representation.
    var localized: LocalizedStringKey {
        switch self {
        case .dynamic: "Dynamic"
        case .mousePointer: "Mouse pointer"
        case .iceIcon: "\(Constants.displayName) icon"
        }
    }

    /// Parses an IceBarLocation from a string value.
    /// Supports exact case names: "dynamic", "mousePointer", "iceIcon"
    /// Or raw integer values: "0", "1", "2"
    static func fromString(_ value: String) -> IceBarLocation? {
        switch value {
        case "dynamic", "0":
            return .dynamic
        case "mousePointer", "1":
            return .mousePointer
        case "iceIcon", "2":
            return .iceIcon
        default:
            return nil
        }
    }
}

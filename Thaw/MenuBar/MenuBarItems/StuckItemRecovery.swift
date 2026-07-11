//
//  StuckItemRecovery.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

/// Detects and recovers menu bar items that get stuck in an invalid state.
///
/// macOS can sometimes place menu bar items at x=-1 (off-screen), where they
/// become unresponsive to interactions. This tracker identifies such items
/// and attempts automatic recovery by moving them to a valid position.
@MainActor
final class StuckItemRecovery {
    /// Information about a stuck item for recovery attempts.
    struct StuckItemInfo {
        let item: MenuBarItem
        let detectedAt: Date
        var recoveryAttempts: Int
        let originalSection: MenuBarSection.Name?
    }

    /// Tracks items currently identified as stuck.
    private var stuckItems: [CGWindowID: StuckItemInfo] = [:]

    /// Items we've successfully recovered, mapped to when they were recovered so
    /// entries can expire (see ``recoveredItemMemoryDuration``). Storing the
    /// timestamp — rather than a bare `Set` that only ever grew — bounds the map
    /// and lets a window ID become eligible for re-recovery after the cooldown.
    private var recoveredItems: [CGWindowID: Date] = [:]

    /// Maximum recovery attempts per item before giving up.
    private let maxRecoveryAttempts = 3

    /// Time to wait before considering an item "stuck".
    private let stuckConfirmationDelay: TimeInterval = 1.0

    /// The x-coordinate threshold for stuck items.
    private let stuckXCoordinate: CGFloat = -1

    /// Time after which to forget about recovered items.
    private let recoveredItemMemoryDuration: TimeInterval = 60.0

    private let diagLog = DiagLog(category: "StuckItemRecovery")

    /// Checks for stuck items in the given list.
    ///
    /// - Parameter items: Current menu bar items
    /// - Returns: Items that are confirmed stuck and ready for recovery
    func detectStuckItems(in items: [MenuBarItem]) -> [MenuBarItem] {
        let now = Date()
        var newlyStuck: [MenuBarItem] = []

        // Forget items recovered longer ago than the memory duration, so the map
        // stays bounded and a stale window ID no longer suppresses re-recovery.
        recoveredItems = recoveredItems.filter { _, recoveredAt in
            now.timeIntervalSince(recoveredAt) < recoveredItemMemoryDuration
        }

        for item in items where !item.isControlItem {
            let bounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds

            if bounds.origin.x == stuckXCoordinate {
                // Item is at stuck position
                if var info = stuckItems[item.windowID] {
                    // Already tracking - check if confirmed stuck
                    if now.timeIntervalSince(info.detectedAt) >= stuckConfirmationDelay,
                       info.recoveryAttempts < maxRecoveryAttempts,
                       recoveredItems[item.windowID] == nil
                    {
                        newlyStuck.append(item)
                        info.recoveryAttempts += 1
                        stuckItems[item.windowID] = info
                    }
                } else {
                    // New potentially stuck item
                    stuckItems[item.windowID] = StuckItemInfo(
                        item: item,
                        detectedAt: now,
                        recoveryAttempts: 0,
                        originalSection: nil // Will determine during recovery
                    )
                }
            } else {
                // Item is not stuck - remove from tracking
                if stuckItems.removeValue(forKey: item.windowID) != nil {
                    diagLog.debug("Item \(item.logString) recovered from stuck state")
                }
            }
        }

        // Clean up tracking for items that disappeared
        let currentWindowIDs = Set(items.map { $0.windowID })
        for windowID in stuckItems.keys where !currentWindowIDs.contains(windowID) {
            stuckItems.removeValue(forKey: windowID)
        }

        return newlyStuck
    }

    /// Attempts to recover a stuck item by moving it to the visible section.
    ///
    /// - Parameters:
    ///   - item: The stuck item to recover
    ///   - controlItems: The current control items for positioning
    ///   - appState: The app state for performing moves
    /// - Returns: True if recovery succeeded
    func recoverStuckItem(
        _ item: MenuBarItem,
        controlItems: (hidden: MenuBarItem, alwaysHidden: MenuBarItem?),
        using moveHandler: (MenuBarItem, MenuBarItemManager.MoveDestination) async throws -> Void
    ) async -> Bool {
        guard let info = stuckItems[item.windowID],
              info.recoveryAttempts < maxRecoveryAttempts
        else {
            return false
        }

        diagLog.info("Attempting to recover stuck item \(item.logString) (attempt \(info.recoveryAttempts + 1)/\(maxRecoveryAttempts))")

        // Strategy: Move to visible section (right of hidden control item)
        let destination = MenuBarItemManager.MoveDestination.rightOfItem(controlItems.hidden)

        do {
            try await moveHandler(item, destination)

            // Verify recovery
            if let newBounds = Bridging.getWindowBounds(for: item.windowID),
               newBounds.origin.x != stuckXCoordinate
            {
                stuckItems.removeValue(forKey: item.windowID)
                recoveredItems[item.windowID] = Date()
                diagLog.info("Successfully recovered \(item.logString) to visible section")
                return true
            } else {
                diagLog.warning("Recovery attempt failed for \(item.logString) - still stuck")
                return false
            }
        } catch {
            diagLog.error("Recovery attempt failed with error: \(error)")
            return false
        }
    }

    /// Marks an item as successfully recovered.
    func markRecovered(_ item: MenuBarItem) {
        stuckItems.removeValue(forKey: item.windowID)
        recoveredItems[item.windowID] = Date()
    }

    /// Returns information about currently tracked stuck items.
    func stuckItemInfo() -> [StuckItemInfo] {
        Array(stuckItems.values)
    }

    /// Returns the number of items currently tracked as stuck.
    var stuckItemCount: Int {
        stuckItems.count
    }

    /// Resets all tracking.
    func reset() {
        stuckItems.removeAll()
        recoveredItems.removeAll()
        diagLog.info("Reset stuck item recovery state")
    }

    /// Checks if an item was recovered within ``recoveredItemMemoryDuration``.
    func wasRecentlyRecovered(_ item: MenuBarItem) -> Bool {
        guard let recoveredAt = recoveredItems[item.windowID] else { return false }
        return Date().timeIntervalSince(recoveredAt) < recoveredItemMemoryDuration
    }
}

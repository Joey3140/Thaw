//
//  PositionConsensus.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

/// Tracks position observations and determines when positions have stabilized.
///
/// This helps prevent false restores and saves by requiring multiple consecutive
/// consistent observations before considering positions "stable". This filters
/// out transient movements during app launches and macOS menu bar updates.
@MainActor
final class PositionConsensus {
    /// Represents a snapshot of item positions at a point in time.
    struct PositionSnapshot: Equatable {
        let timestamp: Date
        let items: [ItemPosition]

        struct ItemPosition: Equatable {
            let identifier: String // tagIdentifier
            let section: MenuBarSection.Name
            let xPosition: CGFloat
            let windowID: CGWindowID
        }

        init(items: [MenuBarItem]) {
            self.timestamp = Date()
            self.items = items
                .filter { !$0.isControlItem }
                .map { item in
                    ItemPosition(
                        identifier: item.tag.tagIdentifier,
                        section: MenuBarSection.Name.visible, // Will be determined by context
                        xPosition: item.bounds.origin.x,
                        windowID: item.windowID
                    )
                }
                .sorted { $0.identifier < $1.identifier }
        }
    }

    /// Minimum number of consistent observations required for consensus.
    private let requiredObservations = 3

    /// Maximum time between observations to be considered part of the same sequence.
    private let observationWindow: TimeInterval = 2.0

    /// Maximum time to wait for consensus before proceeding with best-effort.
    private let maxWaitTime: TimeInterval = 10.0

    /// Recent observations, oldest first.
    private var observations: [PositionSnapshot] = []

    /// Last time we achieved consensus.
    private var lastConsensusTime: Date?

    /// The last consensus snapshot that was achieved.
    private(set) var lastConsensus: PositionSnapshot?

    /// When we first started observing (for timeout detection).
    private var firstObservationTime: Date?

    private let diagLog = DiagLog(category: "PositionConsensus")

    /// Records a new position observation.
    ///
    /// - Parameter items: Current menu bar items
    /// - Returns: True if consensus has been achieved (positions are stable)
    func observe(items: [MenuBarItem]) -> Bool {
        let snapshot = PositionSnapshot(items: items)

        // Track when we first started observing (for timeout)
        if firstObservationTime == nil {
            firstObservationTime = Date()
        }

        // Remove observations that are too old
        let cutoff = Date().addingTimeInterval(-observationWindow)
        observations.removeAll { $0.timestamp < cutoff }

        // Add new observation
        observations.append(snapshot)

        // Keep only the most recent observations
        if observations.count > requiredObservations {
            observations.removeFirst(observations.count - requiredObservations)
        }

        // Check if we have enough observations and they all match
        guard observations.count >= requiredObservations else {
            diagLog.debug("Observations: \(observations.count)/\(requiredObservations) - not enough for consensus")
            return lastConsensus != nil
        }

        // Check if all observations are identical
        let first = observations[0]
        let allMatch = observations.allSatisfy { $0.items == first.items }

        if allMatch {
            lastConsensus = first
            lastConsensusTime = Date()
            firstObservationTime = nil // Reset timeout tracking
            diagLog.debug("Position consensus achieved with \(observations.count) observations")
            return true
        } else {
            // Show what's different for debugging
            if observations.count >= 2 {
                let diff = differences(between: observations[observations.count - 2], and: snapshot)
                if !diff.isEmpty {
                    diagLog.debug("Positions changing: \(diff.joined(separator: ", "))")
                }
            }
            return false
        }
    }

    /// Checks if positions are currently stable (consensus recently achieved).
    var hasRecentConsensus: Bool {
        guard let consensusTime = lastConsensusTime else { return false }
        return Date().timeIntervalSince(consensusTime) < observationWindow
    }

    /// Returns true if we should wait for more observations before acting.
    var shouldWaitForStability: Bool {
        // Require minimum observations for confidence
        guard observations.count >= 2 else { return true }

        // If we have 3+ observations and consensus, we're stable
        if observations.count >= requiredObservations && hasRecentConsensus {
            return false
        }

        // Check timeout - proceed with best-effort after 10s
        if let firstTime = firstObservationTime,
           Date().timeIntervalSince(firstTime) > maxWaitTime
        {
            diagLog.debug("PositionConsensus timeout reached - proceeding with \(observations.count) observations")
            return false
        }

        return true
    }

    /// Returns the identifiers of items that have changed since last consensus.
    func changedItems(in items: [MenuBarItem]) -> [String] {
        guard let consensus = lastConsensus else {
            return items.map { $0.tag.tagIdentifier }
        }

        let currentIDs = Set(items.map { $0.tag.tagIdentifier })
        let consensusIDs = Set(consensus.items.map { $0.identifier })

        return Array(currentIDs.symmetricDifference(consensusIDs))
    }

    /// Compares two snapshots and returns descriptions of differences.
    private func differences(between older: PositionSnapshot, and newer: PositionSnapshot) -> [String] {
        var diffs: [String] = []

        let olderByID = Dictionary(uniqueKeysWithValues: older.items.map { ($0.identifier, $0) })
        let newerByID = Dictionary(uniqueKeysWithValues: newer.items.map { ($0.identifier, $0) })

        // Check for added items
        for id in newerByID.keys where olderByID[id] == nil {
            diffs.append("+\(id)")
        }

        // Check for removed items
        for id in olderByID.keys where newerByID[id] == nil {
            diffs.append("-\(id)")
        }

        // Check for moved items
        for (id, oldPos) in olderByID {
            guard let newPos = newerByID[id] else { continue }
            if abs(oldPos.xPosition - newPos.xPosition) > 5 { // 5px threshold
                diffs.append("~\(id)(\(Int(oldPos.xPosition))→\(Int(newPos.xPosition)))")
            }
        }

        return diffs
    }

    /// Resets all observations.
    func reset() {
        observations.removeAll()
        lastConsensus = nil
        lastConsensusTime = nil
        firstObservationTime = nil
        diagLog.info("Reset position consensus")
    }

    /// Records that an intentional move operation occurred.
    /// This resets consensus since positions are intentionally changing.
    func recordIntentionalMove() {
        observations.removeAll()
        lastConsensusTime = nil
        diagLog.debug("Consensus reset due to intentional move")
    }
}

//
//  InstanceTracker.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

/// Tracks persistent instance indices for multi-item apps.
///
/// When an app with multiple menu bar icons restarts, macOS may create
/// the windows in a different order, causing instance indices to swap.
/// This tracker maintains stable indices by associating them with
/// window title patterns that survive app restarts.
@MainActor
final class InstanceTracker {
    /// Storage key for UserDefaults
    private static let storageKey = "InstanceTracker.knownInstances"

    /// Maps bundle IDs to their known title patterns and assigned indices.
    /// [bundleID: [titlePattern: instanceIndex]]
    private var knownInstances: [String: [String: Int]] = [:]

    /// Items currently being tracked for instance index stability.
    /// Used to detect when all items from an app have loaded.
    private var pendingApps: [String: [(title: String, windowID: CGWindowID)]] = [:]

    /// Timestamp when we first saw items from each app.
    private var firstSeen: [String: Date] = [:]

    /// Set of apps that have been successfully learned (stable patterns).
    private var hasLearnedPatterns: Set<String> = []

    /// Whether pattern learning is currently enabled.
    private(set) var isLearningEnabled: Bool = false

    /// Apps seen before learning was enabled - don't learn these until next launch.
    private var deferredApps: Set<String> = []

    private let diagLog = DiagLog(category: "InstanceTracker")

    init() {
        loadKnownInstances()
    }

    /// Loads persisted instance mappings from UserDefaults.
    private func loadKnownInstances() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String: Int]] {
            knownInstances = stored
            diagLog.debug("Loaded instance mappings for \(stored.count) apps")
        }
    }

    /// Persists the current instance mappings to UserDefaults.
    private func persistKnownInstances() {
        UserDefaults.standard.set(knownInstances, forKey: Self.storageKey)
    }

    /// Assigns stable instance indices to items from the same app.
    ///
    /// - Parameters:
    ///   - items: All menu bar items currently in the cache
    /// - Returns: A mapping from windowID to assigned instance index
    func assignInstanceIndices(for items: [MenuBarItem]) -> [CGWindowID: Int] {
        // Group items by bundle ID
        var itemsByBundleID: [String: [MenuBarItem]] = [:]
        for item in items where !item.isControlItem {
            let bundleID = item.tag.namespace.description
            if bundleID.contains(".") { // Only track apps with proper bundle IDs
                itemsByBundleID[bundleID, default: []].append(item)
            }
        }

        var result: [CGWindowID: Int] = [:]

        for (bundleID, appItems) in itemsByBundleID where appItems.count > 1 {
            // Skip learning if disabled or app was seen before learning enabled
            guard isLearningEnabled else {
                deferredApps.insert(bundleID)
                diagLog.debug("InstanceTracker: deferring learning for \(bundleID) - learning disabled")
                continue
            }
            guard !deferredApps.contains(bundleID) else {
                diagLog.debug("InstanceTracker: skipping \(bundleID) - seen before learning enabled")
                continue
            }

            // Sort by current instance index (from MenuBarItemTag) for stability.
            // When indices are equal, sort by title for deterministic initial assignment.
            let sortedItems = appItems.sorted {
                if $0.tag.instanceIndex == $1.tag.instanceIndex {
                    return $0.tag.title < $1.tag.title
                }
                return $0.tag.instanceIndex < $1.tag.instanceIndex
            }

            // Check if we have known patterns for this app
            var knownPatterns = knownInstances[bundleID, default: [:]]
            var usedIndices = Set<Int>()

            // First pass: match items to known patterns
            for item in sortedItems {
                let title = item.tag.title

                // Try exact match first
                if let index = knownPatterns[title], !usedIndices.contains(index) {
                    result[item.windowID] = index
                    usedIndices.insert(index)
                    continue
                }

                // Try pattern matching for dynamic titles
                if let (pattern, index) = matchToKnownPattern(title: title, patterns: knownPatterns),
                   !usedIndices.contains(index)
                {
                    result[item.windowID] = index
                    usedIndices.insert(index)
                    // Update pattern if it evolved
                    if pattern != title {
                        knownPatterns[title] = index
                        diagLog.debug("Updated pattern for \(bundleID)[\(index)]: '\(pattern)' → '\(title)'")
                    }
                    continue
                }
            }

            // Second pass: assign new indices to unmatched items
            var nextIndex = 0
            for item in sortedItems {
                guard result[item.windowID] == nil else { continue }

                // Find next available index
                while usedIndices.contains(nextIndex) {
                    nextIndex += 1
                }

                result[item.windowID] = nextIndex
                usedIndices.insert(nextIndex)
                knownPatterns[item.tag.title] = nextIndex
                diagLog.debug("Assigned new instance index \(nextIndex) to \(bundleID): '\(item.tag.title)'")
            }

            // Mark app as learned if this is the first time
            if !hasLearnedPatterns.contains(bundleID) {
                hasLearnedPatterns.insert(bundleID)
                diagLog.info("InstanceTracker: learned patterns for \(bundleID)")
            }

            // Persist updated patterns
            if knownPatterns != knownInstances[bundleID] {
                knownInstances[bundleID] = knownPatterns
                persistKnownInstances()
            }
        }

        // Single-item apps always get index 0
        for (_, appItems) in itemsByBundleID where appItems.count == 1 {
            result[appItems[0].windowID] = 0
        }

        return result
    }

    /// Attempts to match a title to a known pattern.
    ///
    /// - Parameters:
    ///   - title: The current window title
    ///   - patterns: Known title patterns mapped to indices
    /// - Returns: The matched pattern and its index, if found
    private func matchToKnownPattern(title: String, patterns: [String: Int]) -> (pattern: String, index: Int)? {
        // Exact match
        if let index = patterns[title] {
            return (title, index)
        }

        // For dynamic titles, try to match by common prefixes or suffixes
        for (pattern, index) in patterns {
            // Check for significant overlap (common prefix or suffix)
            let prefixOverlap = commonPrefixLength(pattern, title)
            let suffixOverlap = commonSuffixLength(pattern, title)

            // If >50% of the shorter string matches as prefix or suffix
            let minLength = min(pattern.count, title.count)
            if minLength > 0, prefixOverlap * 2 >= minLength || suffixOverlap * 2 >= minLength {
                return (pattern, index)
            }
        }

        return nil
    }

    /// Calculates the length of the common prefix between two strings.
    private func commonPrefixLength(_ s1: String, _ s2: String) -> Int {
        let chars1 = Array(s1)
        let chars2 = Array(s2)
        var count = 0
        for i in 0 ..< min(chars1.count, chars2.count) {
            if chars1[i] == chars2[i] {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    /// Calculates the length of the common suffix between two strings.
    private func commonSuffixLength(_ s1: String, _ s2: String) -> Int {
        let chars1 = Array(s1)
        let chars2 = Array(s2)
        var count = 0
        for i in 1 ... min(chars1.count, chars2.count) {
            if chars1[chars1.count - i] == chars2[chars2.count - i] {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    /// Clears all tracked instance mappings.
    /// Called during layout reset.
    func reset() {
        knownInstances.removeAll()
        pendingApps.removeAll()
        firstSeen.removeAll()
        hasLearnedPatterns.removeAll()
        deferredApps.removeAll()
        isLearningEnabled = false
        persistKnownInstances()
        diagLog.info("Reset all instance mappings and learning state")
    }

    /// Enables pattern learning after startup settling is complete.
    func enableLearning() {
        isLearningEnabled = true
        diagLog.info("InstanceTracker: learning enabled")
        // Clear deferred apps - next cache will be first chance to learn them
        deferredApps.removeAll()
    }

    /// Checks if an app has been learned yet.
    func hasLearned(_ bundleID: String) -> Bool {
        hasLearnedPatterns.contains(bundleID)
    }

    /// Removes mappings for apps that are no longer running.
    ///
    /// - Parameter runningBundleIDs: Set of currently running app bundle IDs
    func prune(runningBundleIDs: Set<String>) {
        let beforeCount = knownInstances.count
        knownInstances = knownInstances.filter { runningBundleIDs.contains($0.key) }
        if knownInstances.count != beforeCount {
            persistKnownInstances()
            diagLog.debug("Pruned instance mappings: \(beforeCount) → \(knownInstances.count)")
        }
    }
}

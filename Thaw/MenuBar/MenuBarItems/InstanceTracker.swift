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

    // MARK: - Pattern Observation Tracking

    /// Represents a single pattern observation at a point in time.
    private struct PatternObservation {
        let timestamp: Date
        let patterns: [String: Int] // titlePattern: instanceIndex
    }

    /// Tracks pattern observations per app for consistency verification.
    /// [bundleID: [observations]]
    private var patternObservations: [String: [PatternObservation]] = [:]

    /// Tracks observation attempt counts per app (for fallback cap).
    /// [bundleID: attemptCount]
    private var observationAttemptCounts: [String: Int] = [:]

    /// Tracks last time we checked observations for each app.
    /// [bundleID: lastCheckTime]
    private var lastObservationCheck: [String: Date] = [:]

    /// Timer for frequent observation checking during settling.
    private var observationTimer: Timer?

    /// Whether we're currently in the settling period.
    private var isSettlingPeriod: Bool = false

    /// Minimum consistent observations required before persisting patterns.
    private let requiredConsistentObservations = 3

    /// Time window for observations to be considered part of the same sequence.
    private let observationWindow: TimeInterval = 5.0

    /// Maximum observation attempts before falling back to windowID order.
    private let maxObservationAttempts = 5

    /// Interval for observation timer checks.
    private let observationCheckInterval: TimeInterval = 0.5

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
                diagLog.debug("[InstanceTracker] \(bundleID): DEFERRED - learning disabled")

                // Assign based on windowID order (no persistence)
                for (index, item) in appItems.sorted(by: { $0.windowID < $1.windowID }).enumerated() {
                    result[item.windowID] = index
                }
                continue
            }

            guard !deferredApps.contains(bundleID) else {
                diagLog.debug("[InstanceTracker] \(bundleID): SKIPPED - seen before learning enabled")

                // Assign based on windowID order (no persistence)
                for (index, item) in appItems.sorted(by: { $0.windowID < $1.windowID }).enumerated() {
                    result[item.windowID] = index
                }
                continue
            }

            // Check if we already have known patterns for this app
            if let knownPatterns = knownInstances[bundleID], !knownPatterns.isEmpty {
                // Use known patterns
                var usedIndices = Set<Int>()

                // Sort for stable assignment
                let sortedItems = appItems.sorted {
                    if $0.tag.instanceIndex == $1.tag.instanceIndex {
                        return $0.tag.title < $1.tag.title
                    }
                    return $0.tag.instanceIndex < $1.tag.instanceIndex
                }

                // Match items to known patterns
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
                        diagLog.debug("[InstanceTracker] \(bundleID): Matched pattern '\(title)' -> index \(index) (from '\(pattern)'")
                        continue
                    }
                }

                // Assign remaining indices
                var nextIndex = 0
                for item in sortedItems {
                    guard result[item.windowID] == nil else { continue }
                    while usedIndices.contains(nextIndex) {
                        nextIndex += 1
                    }
                    result[item.windowID] = nextIndex
                    usedIndices.insert(nextIndex)
                    diagLog.debug("[InstanceTracker] \(bundleID): Assigned index \(nextIndex) to new item '\(item.tag.title)'")
                }

                diagLog.debug("[InstanceTracker] \(bundleID): Using known patterns")
                continue
            }

            // NEW APP: Need to learn patterns through observation
            // Sort by current instance index for stability
            let sortedItems = appItems.sorted {
                if $0.tag.instanceIndex == $1.tag.instanceIndex {
                    return $0.tag.title < $1.tag.title
                }
                return $0.tag.instanceIndex < $1.tag.instanceIndex
            }

            // Build current pattern observation
            let currentPatterns = buildPatterns(from: sortedItems)
            let observation = PatternObservation(timestamp: Date(), patterns: currentPatterns)

            // Store observation
            var observations = patternObservations[bundleID, default: []]
            observations.append(observation)

            // Clean old observations (>5s)
            let cutoff = Date().addingTimeInterval(-observationWindow)
            observations.removeAll { $0.timestamp < cutoff }
            patternObservations[bundleID] = observations

            // Increment attempt count
            let attempts = observationAttemptCounts[bundleID, default: 0] + 1
            observationAttemptCounts[bundleID] = attempts

            diagLog.debug("[InstanceTracker] \(bundleID): OBSERVED pattern (attempt \(attempts)/\(maxObservationAttempts))")

            // Check for consistency
            let isConsistent = arePatternsConsistent(observations)
            let shouldFallback = attempts >= maxObservationAttempts

            if isConsistent {
                // PERSIST: Patterns are stable
                persistPatterns(bundleID: bundleID, patterns: currentPatterns)
                hasLearnedPatterns.insert(bundleID)
                observationAttemptCounts[bundleID] = 0 // Reset attempts
                diagLog.info("[InstanceTracker] \(bundleID): PERSISTED after \(observations.count) consistent observations")

                // Apply to result
                for item in sortedItems {
                    if let index = currentPatterns[item.tag.title] {
                        result[item.windowID] = index
                    }
                }
            } else if shouldFallback {
                // FALLBACK: Max attempts reached, use windowID order
                diagLog.warning("[InstanceTracker] \(bundleID): FALLBACK after \(attempts) attempts - using windowID order")
                observationAttemptCounts[bundleID] = 0 // Reset for next time

                // Assign based on current windowID order (no persistence)
                for (index, item) in sortedItems.enumerated() {
                    result[item.windowID] = index
                }
            } else {
                // WAITING: Not consistent yet, use windowID order temporarily
                diagLog.debug("[InstanceTracker] \(bundleID): WAITING - \(observations.count)/\(requiredConsistentObservations) consistent observations")

                // Assign based on current windowID order (no persistence)
                for (index, item) in sortedItems.enumerated() {
                    result[item.windowID] = index
                }
            }
        }

        // Single-item apps always get index 0
        for (_, appItems) in itemsByBundleID where appItems.count == 1 {
            result[appItems[0].windowID] = 0
        }

        // Log summary
        let learnedCount = hasLearnedPatterns.count
        let observingCount = patternObservations.keys.count
        let deferredCount = deferredApps.count
        diagLog.debug("[InstanceTracker] Summary: \(learnedCount) learned, \(observingCount) observing, \(deferredCount) deferred")

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

    // MARK: - Pattern Observation Timer

    /// Starts the observation timer for frequent consistency checks during settling.
    func startObservationTimer() {
        guard observationTimer == nil else { return }
        isSettlingPeriod = true
        observationTimer = Timer.scheduledTimer(withTimeInterval: observationCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAllObservations()
            }
        }
        diagLog.debug("[InstanceTracker] Observation timer started (500ms interval)")

        // Auto-stop after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.stopObservationTimer()
        }
    }

    /// Stops the observation timer.
    func stopObservationTimer() {
        observationTimer?.invalidate()
        observationTimer = nil
        isSettlingPeriod = false
        diagLog.debug("[InstanceTracker] Observation timer stopped")
    }

    /// Checks all apps for pattern consistency (called by timer).
    private func checkAllObservations() {
        for (bundleID, observations) in patternObservations {
            guard observations.count >= requiredConsistentObservations else { continue }

            if arePatternsConsistent(observations) {
                // Persist immediately when consistency detected
                if let lastObservation = observations.last {
                    persistPatterns(bundleID: bundleID, patterns: lastObservation.patterns)
                    hasLearnedPatterns.insert(bundleID)
                    diagLog.info("[InstanceTracker] \(bundleID): Early persist via timer after \(observations.count) observations")
                }
            }
        }
    }

    /// Checks if the last N observations are consistent.
    private func arePatternsConsistent(_ observations: [PatternObservation]) -> Bool {
        guard observations.count >= requiredConsistentObservations else { return false }
        let lastN = Array(observations.suffix(requiredConsistentObservations))
        guard let firstObservation = lastN.first else { return false }
        let firstPatterns = firstObservation.patterns
        let isConsistent = lastN.allSatisfy { $0.patterns == firstPatterns }

        if isConsistent {
            diagLog.debug("[InstanceTracker] Patterns CONSISTENT across \(requiredConsistentObservations) observations")
        }

        return isConsistent
    }

    /// Builds a pattern dictionary from items.
    /// Handles duplicate titles gracefully by using the first occurrence.
    private func buildPatterns(from items: [MenuBarItem]) -> [String: Int] {
        var patterns = [String: Int]()
        for item in items {
            let title = item.tag.title
            if patterns[title] == nil {
                patterns[title] = item.tag.instanceIndex
            } else {
                diagLog.warning("[InstanceTracker] Duplicate title '\(title)' encountered, using first occurrence")
            }
        }
        return patterns
    }

    /// Persists patterns for an app.
    private func persistPatterns(bundleID: String, patterns: [String: Int]) {
        knownInstances[bundleID] = patterns
        persistKnownInstances()
    }

    /// Clears all tracked instance mappings.
    /// Called during layout reset.
    func reset() {
        knownInstances.removeAll()
        pendingApps.removeAll()
        firstSeen.removeAll()
        hasLearnedPatterns.removeAll()
        deferredApps.removeAll()
        patternObservations.removeAll()
        observationAttemptCounts.removeAll()
        lastObservationCheck.removeAll()
        stopObservationTimer()
        isLearningEnabled = false
        persistKnownInstances()
        diagLog.info("[InstanceTracker] Full reset completed")
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
        let allBundleIDs = Set(knownInstances.keys)
        knownInstances = knownInstances.filter { runningBundleIDs.contains($0.key) }

        // Also clear observation state for terminated apps
        let removedBundleIDs = allBundleIDs.subtracting(runningBundleIDs)
        for bundleID in removedBundleIDs {
            observationAttemptCounts.removeValue(forKey: bundleID)
            patternObservations.removeValue(forKey: bundleID)
            lastObservationCheck.removeValue(forKey: bundleID)
            hasLearnedPatterns.remove(bundleID)
            diagLog.debug("[InstanceTracker] Cleared observation state for terminated app \(bundleID)")
        }

        if knownInstances.count != beforeCount {
            persistKnownInstances()
            diagLog.debug("[InstanceTracker] Pruned instance mappings: \(beforeCount) → \(knownInstances.count)")
        }
    }
}

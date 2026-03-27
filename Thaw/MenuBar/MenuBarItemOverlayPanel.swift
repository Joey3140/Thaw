//
//  MenuBarItemOverlayPanel.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AXSwift
import Cocoa
import Combine
import SwiftUI

// MARK: - MenuBarItemOverlayPanel

/// A panel that replaces the macOS menu bar's status item area with
/// a custom-rendered view, displaying item images from the cache in
/// the desired order.
///
/// The actual macOS status items remain on-screen underneath (with
/// `ControlItem.Lengths.expanded = 0`) so ScreenCaptureKit can capture
/// them, but this panel covers them entirely. Clicks are forwarded to
/// the correct actual item via `itemManager.click()`.
///
/// System items (Control Center, Clock, Siri) are NOT covered — the
/// panel stops at the leftmost system item's boundary.
@MainActor
final class MenuBarItemOverlayPanel: NSPanel {
    private let diagLog = DiagLog(category: "MenuBarItemOverlayPanel")

    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var imageRefreshTask: Task<Void, Never>?
    private var rehideTimer: DispatchWorkItem?

    /// Visible items that were clipped due to insufficient space.
    /// These are prepended to the hidden section when it is expanded.
    private var clippedVisibleItems = [MenuBarItem]()

    /// The overlay's resolved section assignments. Used by the IceBar
    /// to look up items when position-based detection is unreliable.
    private(set) var resolvedSections = [MenuBarSection.Name: [MenuBarItem]]()

    /// The current index of the virtual Thaw icon within visible items.
    private var currentThawIconIndex: Int = 0

    /// Virtual section visibility — purely in-memory, no physical control
    /// item state changes needed. Toggling is instant.
    @Published private(set) var shownSections = Set<MenuBarSection.Name>()

    /// An opaque panel between the overlay and the physical items.
    /// Provides a clean background so the overlay's visual effect
    /// blurs the desktop wallpaper, not the icons underneath.
    private let backgroundPanel = MenuBarBackgroundPanel()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.title = "Thaw Item Overlay"
        self.titlebarAppearsTransparent = true
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.hasShadow = false
        // Same level as status bar items so other notch apps can appear above.
        // The background panel is ordered first, then this overlay on top.
        self.level = .statusBar
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .moveToActiveSpace, .stationary]
        self.hidesOnDeactivate = false
        self.canHide = false
        self.ignoresMouseEvents = false
    }

    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        startImageRefreshLoop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
        }
    }

    /// Periodically refreshes item images so the overlay always shows
    /// current icons (prevents stale cache → app icon fallback).
    private func startImageRefreshLoop() {
        imageRefreshTask?.cancel()
        imageRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // Fast refresh for smooth animated icons (~60fps).
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self, let appState = self.appState else { break }

                let allItems = appState.itemManager.itemCache.managedItems
                    .filter { !$0.isControlItem }
                guard !allItems.isEmpty else { continue }

                let displayID = appState.itemManager.itemCache.displayID
                    ?? Bridging.getActiveMenuBarDisplayID()
                    ?? CGMainDisplayID()
                guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                    continue
                }

                await appState.imageCache.refreshImages(
                    of: allItems,
                    scale: screen.backingScaleFactor
                )
            }
        }
    }

    /// Whether any section is currently expanded (inline or via IceBar).
    var isSectionExpanded: Bool {
        !shownSections.isEmpty || appState?.navigationState.isIceBarPresented == true
    }

    /// Single click: if collapsed → show hidden items (inline or IceBar).
    /// If expanded → collapse all.
    func toggleHidden() {
        guard let appState else { return }
        if isSectionExpanded {
            // Collapse everything.
            shownSections.removeAll()
            rehideTimer?.cancel()
            appState.menuBarManager.iceBarPanel.close()
            appState.menuBarManager.showOnHoverAllowed = true
            updateContent()
        } else {
            // Expand hidden section.
            if useIceBar {
                showIceBar(section: .hidden)
            } else {
                shownSections.insert(.hidden)
                scheduleRehide()
                refresh()
            }
        }
    }

    /// Double click: show always-hidden items (inline or IceBar).
    func showAll() {
        guard let appState else { return }
        if useIceBar {
            // If IceBar is already showing always-hidden, collapse instead.
            if appState.menuBarManager.iceBarPanel.currentSection == .alwaysHidden {
                appState.menuBarManager.iceBarPanel.close()
                appState.menuBarManager.showOnHoverAllowed = true
                updateContent()
                return
            }
            showIceBar(section: .alwaysHidden)
        } else {
            shownSections.insert(.hidden)
            shownSections.insert(.alwaysHidden)
            scheduleRehide()
            refresh()
        }
    }

    /// Whether the current display is configured to use the IceBar.
    private var useIceBar: Bool {
        guard let appState else { return false }
        let displayID = appState.itemManager.itemCache.displayID
            ?? Bridging.getActiveMenuBarDisplayID()
            ?? CGMainDisplayID()
        return appState.settings.displaySettings.useIceBar(for: displayID)
    }

    /// Shows the IceBar positioned under the overlay's Thaw icon.
    private func showIceBar(section: MenuBarSection.Name) {
        guard let appState,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.intersects(frame)
              })
        else { return }

        // Set the overlay's anchor hint so the IceBar positions
        // under the Thaw icon instead of the physical control item.
        appState.menuBarManager.iceBarAnchorOverride = thawIconMidX

        appState.menuBarManager.iceBarPanel.show(
            section: section,
            on: screen
        )
    }

    /// Returns the screen-space midX of the overlay's Thaw icon.
    /// The screen-space midX of the virtual Thaw icon.
    var thawIconMidX: CGFloat? {
        guard let appState, appState.settings.general.showIceIcon else { return nil }
        let visible = resolvedSections[.visible] ?? []
        // Measure width of items to the right of the Thaw icon.
        let itemsAfterThaw = visible.dropFirst(currentThawIconIndex)
        var rightOffset: CGFloat = 0
        for item in itemsAfterThaw {
            if let cached = appState.imageCache.images[item.tag] {
                rightOffset += cached.scaledSize.width
            } else if item.sourceApplication?.icon != nil {
                rightOffset += 22
            }
        }
        return frame.maxX - rightOffset - 7 // Half of 14pt icon width
    }

    /// Schedules automatic collapse based on the user's rehide settings.
    private func scheduleRehide() {
        rehideTimer?.cancel()
        guard let appState, appState.settings.general.autoRehide else { return }
        let interval = appState.settings.general.rehideInterval
        let work = DispatchWorkItem { [weak self] in
            guard let self, let appState = self.appState, !self.shownSections.isEmpty else { return }
            self.shownSections.removeAll()
            appState.menuBarManager.showOnHoverAllowed = true
            self.refresh()
        }
        rehideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// Called when MenuBarSection states change externally (hotkey, etc.).
    /// Syncs the overlay's virtual sections to match.
    private func syncShownSectionsFromExternal() {
        guard let appState else { return }

        // When the IceBar is configured, sections should not expand
        // inline in the overlay — the IceBar handles display.
        // Only update the icon state via updateContent().
        if useIceBar {
            updateContent()
            return
        }

        var sections = Set<MenuBarSection.Name>()
        if let hidden = appState.menuBarManager.section(withName: .hidden),
           !hidden.isHidden
        {
            sections.insert(.hidden)
        }
        if let alwaysHidden = appState.menuBarManager.section(withName: .alwaysHidden),
           !alwaysHidden.isHidden
        {
            sections.insert(.alwaysHidden)
        }
        if sections != shownSections {
            shownSections = sections
            refresh()
        }
    }

    /// Returns `true` when the mouse is inside the overlay's empty area
    /// (the Spacer region to the left of rendered items). Used by
    /// HIDEventManager for show-on-hover detection.
    func isMouseInsideEmptyArea() -> Bool {
        guard isVisible, let mouseLocation = MouseHelpers.locationAppKit else {
            return false
        }
        guard frame.contains(mouseLocation) else { return false }
        // Only the Spacer region (left of rendered items) counts as empty.
        guard let appState else { return false }
        var itemsWidth: CGFloat = appState.settings.general.showIceIcon ? 14 : 0
        let visibleItems = resolvedSections[.visible] ?? []
        for item in visibleItems {
            if let cached = appState.imageCache.images[item.tag] {
                itemsWidth += cached.scaledSize.width
            } else if item.sourceApplication?.icon != nil {
                itemsWidth += 22
            }
        }
        itemsWidth += appState.settings.general.itemSpacingOffset * CGFloat(visibleItems.count)
        let itemsLeftEdge = frame.maxX - itemsWidth
        return mouseLocation.x < itemsLeftEdge
    }

    /// Full refresh: recalculate frame and update content.
    private func refresh() {
        updateFrame()
        updateContent()
    }

    // MARK: - Observers

    private func configureCancellables() {
        guard let appState else { return }
        var c = Set<AnyCancellable>()

        // Re-render when Ice icon or showIceIcon changes.
        appState.settings.general.$iceIcon
            .combineLatest(
                appState.settings.general.$showIceIcon,
                appState.settings.general.$customIceIconIsTemplate
            )
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &c)

        // Refresh when item spacing changes.
        appState.settings.general.$itemSpacingOffset
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &c)

        // Refresh when image cache changes.
        appState.imageCache.$images
            .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &c)

        // Refresh when item cache changes.
        appState.itemManager.$itemCache
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &c)

        // Refresh on screen/space changes. Debounce screen parameter
        // changes to let the system settle after display swaps.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &c)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &c)

        // Refresh on space changes (also triggers when menu bar moves displays).
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.activeSpaceDidChangeNotification
        )
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refresh()
            self?.backgroundPanel.updateWallpaper()
        }
        .store(in: &c)

        // Sync overlay when section visibility changes externally
        // (via hotkey, real control item click, or any other source).
        for section in appState.menuBarManager.sections {
            section.$desiredState
                .removeDuplicates()
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.syncShownSectionsFromExternal()
                }
                .store(in: &c)
        }

        // Update Thaw icon when IceBar opens/closes.
        appState.navigationState.$isIceBarPresented
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &c)

        // Hide/show with system menu bar.
        appState.menuBarManager.$isMenuBarHiddenBySystem
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isHidden in
                if isHidden {
                    self?.orderOut(nil)
                    self?.backgroundPanel.orderOut(nil)
                } else {
                    self?.refresh()
                }
            }
            .store(in: &c)

        // Refresh when active profile changes (re-render in new order).
        appState.profileManager.$activeLayout
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &c)

        cancellables = c
    }

    // MARK: - Item Ordering

    /// Sorts items according to a profile's ordered identifiers.
    /// Items in the order list are sorted by their profile position.
    /// Items NOT in the order list maintain their physical position
    /// (by X coordinate) and are interleaved among the ordered items
    /// at their natural location.
    private func sortItems(
        _ items: [MenuBarItem],
        by orderedIDs: [String]
    ) -> [MenuBarItem] {
        guard !orderedIDs.isEmpty else { return items }

        let orderMap = Dictionary(
            orderedIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        // Sort matched items by profile position. Unmatched items go at the
        // beginning (leftmost, near the Thaw icon) so new icons don't appear
        // next to the clock/system items.
        let ordered = items
            .filter { orderMap[$0.uniqueIdentifier] != nil }
            .sorted { (orderMap[$0.uniqueIdentifier] ?? 0) < (orderMap[$1.uniqueIdentifier] ?? 0) }
        let unordered = items.filter { orderMap[$0.uniqueIdentifier] == nil }

        return unordered + ordered
    }

    // MARK: - Frame

    /// Positions the panel over the full status item area (right of app menus).
    private func updateFrame() {
        guard let appState else { return }

        let displayID = appState.itemManager.itemCache.displayID
            ?? Bridging.getActiveMenuBarDisplayID()
            ?? CGMainDisplayID()

        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            return
        }

        let menuBarHeight = screen.getMenuBarHeightEstimate()

        // Fill the entire space between app menus and the right edge.
        // System items (Clock, Control Center) sit at the same window
        // level and render natively above the overlay's background.
        // The Spacer in the content view pushes icons to the right.
        let overlayRight = screen.frame.maxX

        // Start from the right edge of the frontmost app's menus.
        // On notched displays, app menus are left of the notch —
        // the overlay extends from there rightward. Items are
        // right-aligned by the Spacer so the notch area is just
        // clean background.
        var overlayLeft = screen.frame.minX
        if let appMenuMaxX = AXHelpers.frontmostAppMenuBarMaxX() {
            overlayLeft = max(overlayLeft, appMenuMaxX)
        }
        let overlayWidth = overlayRight - overlayLeft
        guard overlayWidth > 20 else {
            orderOut(nil)
            return
        }

        let newFrame = CGRect(
            x: overlayLeft,
            y: screen.frame.maxY - menuBarHeight,
            width: overlayWidth,
            height: menuBarHeight
        )

        setFrame(newFrame, display: true)

        // Position background panel at the same frame, one level below.
        backgroundPanel.setFrame(newFrame, display: true)
        backgroundPanel.updateWallpaper()

        if !isVisible {
            backgroundPanel.orderFrontRegardless()
            orderFrontRegardless()
            diagLog.debug("updateFrame: overlay shown at \(newFrame)")
        }
    }

    // MARK: - Content

    /// Rebuilds the SwiftUI content with current items.
    private func updateContent() {
        guard let appState else { return }

        // All items from the cache (no control items — the visible control
        // item no longer has a physical status item).
        let allItems = appState.itemManager.itemCache.managedItems
            .filter { !$0.isControlItem }

        var visibleItems: [MenuBarItem]
        var hiddenItems = [MenuBarItem]()
        var alwaysHiddenItems = [MenuBarItem]()
        // Index within visibleItems where the virtual Thaw icon should be
        // inserted. `nil` means append at the end (default position).
        var thawIconIndex: Int?

        if let layout = appState.profileManager.activeLayout,
           let sectionMap = layout.itemSectionMap, !sectionMap.isEmpty
        {
            // Profile is active — use its itemSectionMap to assign items
            // to sections, overriding the position-based detection.
            var visible = [MenuBarItem]()
            var hidden = [MenuBarItem]()
            var alwaysHidden = [MenuBarItem]()
            var unassigned = [MenuBarItem]()

            for item in allItems {
                let section = sectionMap[item.uniqueIdentifier]
                switch section {
                case "visible":
                    visible.append(item)
                case "hidden":
                    hidden.append(item)
                case "alwaysHidden":
                    alwaysHidden.append(item)
                default:
                    unassigned.append(item)
                }
            }

            // Sort each section by the profile's itemOrder.
            let itemOrder = layout.itemOrder ?? [:]
            // Unassigned items go before ordered visible items so they
            // appear at the left (near the Thaw icon), not at the right
            // (near system items like the clock).
            visibleItems = sortItems(unassigned + visible, by: itemOrder["visible"] ?? [])
            hiddenItems = sortItems(hidden, by: itemOrder["hidden"] ?? [])
            alwaysHiddenItems = sortItems(alwaysHidden, by: itemOrder["alwaysHidden"] ?? [])

            // Find the Thaw icon's position from the profile's visible order.
            let thawUID = "\(Constants.bundleIdentifier):\(ControlItem.Identifier.visible.rawValue)"
            if let visibleOrder = itemOrder["visible"],
               let thawOrderIdx = visibleOrder.firstIndex(of: thawUID)
            {
                // Count how many real items come before the Thaw icon in the order.
                let itemsBefore = visibleOrder[0..<thawOrderIdx].filter { $0 != thawUID }
                thawIconIndex = min(itemsBefore.count, visibleItems.count)
            }
        } else {
            // No profile — use position-based section detection from item cache.
            // Thaw icon goes at the start (leftmost in visible section).
            visibleItems = appState.itemManager.itemCache.managedItems(for: .visible)
                .filter { !$0.isControlItem }
            hiddenItems = appState.itemManager.itemCache.managedItems(for: .hidden)
                .filter { !$0.isControlItem }
            alwaysHiddenItems = appState.itemManager.itemCache.managedItems(for: .alwaysHidden)
                .filter { !$0.isControlItem }
            thawIconIndex = 0
        }

        // Store resolved section assignments for the IceBar to use.
        resolvedSections = [
            .visible: visibleItems,
            .hidden: hiddenItems,
            .alwaysHidden: alwaysHiddenItems,
        ]

        // Only include hidden/alwaysHidden items when their sections
        // are shown in the virtual overlay (no physical state change).
        if !shownSections.contains(.hidden) {
            hiddenItems = []
        }
        if !shownSections.contains(.alwaysHidden) {
            alwaysHiddenItems = []
        }

        // Prepend previously clipped visible items to the hidden section
        // so they become accessible when the user expands hidden items.
        if shownSections.contains(.hidden), !clippedVisibleItems.isEmpty {
            hiddenItems += clippedVisibleItems
        }

        // Trim items that don't fit within the usable panel width.
        // On notched displays, items cannot render under the notch,
        // so the usable width is from the notch's right edge to the
        // panel's right edge (items are right-aligned by the Spacer).
        let displayID = appState.itemManager.itemCache.displayID
            ?? Bridging.getActiveMenuBarDisplayID()
            ?? CGMainDisplayID()
        let screen = NSScreen.screens.first { $0.displayID == displayID }
        // Available width = total panel width minus the notch gap + left padding.
        var availableWidth = frame.width
        if let notch = screen?.frameOfNotch, notch.maxX > frame.minX, notch.minX < frame.maxX {
            availableWidth -= notch.width
        }
        var usedWidth: CGFloat = 0

        // Helper to measure an item's width.
        func itemWidth(_ item: MenuBarItem) -> CGFloat {
            if let cached = appState.imageCache.images[item.tag] {
                return cached.scaledSize.width
            } else if item.sourceApplication?.icon != nil {
                return 22
            }
            return 0
        }

        // Split visible items around the virtual Thaw icon position.
        // The Thaw icon itself is never clipped. Items on both sides
        // can be clipped, but we prioritize keeping items from the right.
        // Clip order: alwaysHidden → hidden → leftOfThaw → rightOfThaw
        // (rightOfThaw clips from the left, i.e. furthest from right edge).
        let effectiveThawIdx = thawIconIndex ?? 0
        let leftOfThaw = Array(visibleItems.prefix(effectiveThawIdx))
        let rightOfThaw = Array(visibleItems.dropFirst(effectiveThawIdx))

        // The Thaw icon width (fixed, never clipped).
        let thawWidth: CGFloat = appState.settings.general.showIceIcon ? 14 : 0

        // Clippable items in clip-priority order (first to be dropped → last):
        // [alwaysHidden] [hidden] [leftOfThaw] [rightOfThaw]
        let clippable = alwaysHiddenItems + hiddenItems + leftOfThaw + rightOfThaw
        var totalWidth = usedWidth + thawWidth + clippable.reduce(CGFloat(0)) { $0 + itemWidth($1) }
        var fittingStartIndex = 0

        while totalWidth > availableWidth, fittingStartIndex < clippable.count {
            totalWidth -= itemWidth(clippable[fittingStartIndex])
            fittingStartIndex += 1
        }

        // Track which visible items were clipped (only when sections are collapsed).
        if shownSections.isEmpty {
            let ahCount = alwaysHiddenItems.count
            let hCount = hiddenItems.count
            let leftCount = leftOfThaw.count
            let clippedFromLeft = max(0, min(fittingStartIndex - ahCount - hCount, leftCount))
            let clippedFromRight = max(0, fittingStartIndex - ahCount - hCount - leftCount)
            var clipped = [MenuBarItem]()
            if clippedFromLeft > 0 {
                clipped += Array(leftOfThaw.prefix(clippedFromLeft))
            }
            if clippedFromRight > 0 {
                clipped += Array(rightOfThaw.prefix(clippedFromRight))
            }
            clippedVisibleItems = clipped
            if !clipped.isEmpty {
                resolvedSections[.hidden] = (resolvedSections[.hidden] ?? []) + clipped
            }
        }

        if fittingStartIndex > 0 {
            let ahCount = alwaysHiddenItems.count
            let hCount = hiddenItems.count
            let leftCount = leftOfThaw.count
            var remaining = fittingStartIndex

            if remaining > 0, !alwaysHiddenItems.isEmpty {
                let drop = min(remaining, ahCount)
                alwaysHiddenItems.removeFirst(drop)
                remaining -= drop
            }
            if remaining > 0, !hiddenItems.isEmpty {
                let drop = min(remaining, hCount)
                hiddenItems.removeFirst(drop)
                remaining -= drop
            }
            if remaining > 0, remaining <= leftCount {
                // Only some leftOfThaw items clipped.
                visibleItems.removeFirst(remaining)
                remaining = 0
            } else if remaining > 0 {
                // All leftOfThaw items clipped, plus some rightOfThaw.
                let rightClip = remaining - leftCount
                // Remove all leftOfThaw items.
                visibleItems.removeFirst(min(leftCount, visibleItems.count))
                // Remove rightOfThaw items from the start (they're now at the beginning).
                let drop = min(rightClip, visibleItems.count)
                if drop > 0 {
                    visibleItems.removeFirst(drop)
                }
            }
        }

        diagLog.debug("updateContent: rendering \(visibleItems.count) visible + \(hiddenItems.count) hidden + \(alwaysHiddenItems.count) always-hidden items")

        // Compute the Thaw icon image.
        let icon = appState.settings.general.iceIcon
        // Show "visible" icon when any section is expanded, "hidden" when all collapsed.
        let isExpanded = isSectionExpanded
        var thawIconImage: NSImage? = isExpanded
            ? icon.visible.nsImage(for: appState)
            : icon.hidden.nsImage(for: appState)
        if case .custom = icon.name, let original = thawIconImage {
            let w = original.size.width
            let h = original.size.height
            let ratio = max(w / 25, h / 17)
            thawIconImage = original.resized(to: CGSize(width: w / ratio, height: h / ratio))
        }

        // Calculate the notch gap width relative to the panel, if applicable.
        var notchGapWidth: CGFloat = 0
        var notchRightEdgeInPanel: CGFloat = 0
        if let notch = screen?.frameOfNotch, notch.maxX > frame.minX, notch.minX < frame.maxX {
            let leftPadding: CGFloat = 24
            notchGapWidth = notch.width + leftPadding
            notchRightEdgeInPanel = frame.maxX - notch.maxX
        }

        currentThawIconIndex = effectiveThawIdx
        // Recalculate Thaw icon index after clipping.
        // leftOfThaw items may have been removed from the start of visibleItems.
        let clippedLeft = max(0, effectiveThawIdx - (visibleItems.count - rightOfThaw.count + leftOfThaw.count - effectiveThawIdx))
        let adjustedThawIndex = max(0, effectiveThawIdx - clippedLeft)
        let finalThawIndex = min(adjustedThawIndex, visibleItems.count)

        let contentView = OverlayContentView(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            alwaysHiddenItems: alwaysHiddenItems,
            imageCache: appState.imageCache,
            itemManager: appState.itemManager,
            menuBarManager: appState.menuBarManager,
            thawIconImage: thawIconImage,
            showThawIcon: appState.settings.general.showIceIcon,
            menuBarHeight: frame.height,
            thawIconIndex: finalThawIndex,
            notchGapWidth: notchGapWidth,
            notchRightEdgeInPanel: notchRightEdgeInPanel,
            spacingOffset: appState.settings.general.itemSpacingOffset,
            onToggleHidden: { [weak self] in self?.toggleHidden() },
            onShowAlwaysHidden: { [weak self] in self?.showAll() }
        )

        let clearContent = contentView.background(Color.clear)
        let hostingView = OverlayHostingView(rootView: clearContent)
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.layer?.backgroundColor = .clear
        // Clip overflow so items that don't fit are hidden from the left.
        hostingView.layer?.masksToBounds = true
        self.contentView = hostingView
    }
}

// MARK: - OverlayContentView

private struct OverlayContentView: View {
    let visibleItems: [MenuBarItem]
    let hiddenItems: [MenuBarItem]
    let alwaysHiddenItems: [MenuBarItem]
    @ObservedObject var imageCache: MenuBarItemImageCache
    @ObservedObject var itemManager: MenuBarItemManager
    @ObservedObject var menuBarManager: MenuBarManager
    let thawIconImage: NSImage?
    let showThawIcon: Bool
    let menuBarHeight: CGFloat
    /// Index within `visibleItems` where the Thaw icon is inserted.
    let thawIconIndex: Int
    /// Width of the notch gap (0 on non-notched displays).
    let notchGapWidth: CGFloat
    /// Distance from the panel's right edge to the notch's right edge.
    let notchRightEdgeInPanel: CGFloat
    /// Spacing offset between items (from settings).
    let spacingOffset: CGFloat
    let onToggleHidden: () -> Void
    let onShowAlwaysHidden: () -> Void

    /// All items in render order (left-to-right), including the Thaw icon placeholder.
    private enum RenderElement: Identifiable {
        case item(MenuBarItem)
        case thawIcon

        var id: String {
            switch self {
            case .item(let item): return "item-\(item.windowID)"
            case .thawIcon: return "thaw-icon"
            }
        }
    }

    /// Builds the flat list of render elements in left-to-right order.
    /// The virtual Thaw icon is inserted at `thawIconIndex` within
    /// the visible items.
    private var allElements: [RenderElement] {
        var elements = [RenderElement]()
        for item in alwaysHiddenItems { elements.append(.item(item)) }
        for item in hiddenItems { elements.append(.item(item)) }
        for (i, item) in visibleItems.enumerated() {
            if i == thawIconIndex, showThawIcon {
                elements.append(.thawIcon)
            }
            elements.append(.item(item))
        }
        // If thawIconIndex is at the end (or beyond), append it after all items.
        if thawIconIndex >= visibleItems.count, showThawIcon {
            elements.append(.thawIcon)
        }
        return elements
    }

    /// Measures the width of a render element.
    private func elementWidth(_ element: RenderElement) -> CGFloat {
        switch element {
        case .item(let item):
            if let cached = imageCache.images[item.tag] {
                return cached.scaledSize.width
            } else if item.sourceApplication?.icon != nil {
                return 22
            }
            return 0
        case .thawIcon:
            return 14
        }
    }

    var body: some View {
        // Layout: [spacer] [left-of-notch items] [notch gap] [right-of-notch items]
        let elements = allElements
        let split = notchSplitIndex(elements: elements)

        HStack(spacing: 0) {
            Spacer(minLength: 0)

            // Items to the left of the notch (overflow items).
            if split > 0 {
                ForEach(elements[0..<split]) { element in
                    renderElement(element)
                }

                // Notch gap spacer.
                Spacer()
                    .frame(width: notchGapWidth)
            }

            // Items to the right of the notch (primary items).
            ForEach(elements[split..<elements.count]) { element in
                renderElement(element)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Returns the index in `elements` where the split between
    /// left-of-notch and right-of-notch items occurs. Items are
    /// placed right-to-left; when accumulated width exceeds the
    /// space to the right of the notch, remaining items go left.
    private func notchSplitIndex(elements: [RenderElement]) -> Int {
        guard notchGapWidth > 0 else { return 0 }

        var rightWidth: CGFloat = 0
        let rightLimit = notchRightEdgeInPanel

        // Walk from the right end (last element) leftward.
        var splitIndex = elements.count
        for i in stride(from: elements.count - 1, through: 0, by: -1) {
            let w = elementWidth(elements[i])
            if rightWidth + w > rightLimit {
                splitIndex = i + 1
                break
            }
            rightWidth += w
            if i == 0 { splitIndex = 0 }
        }

        return min(splitIndex, elements.count)
    }

    @ViewBuilder
    private func renderElement(_ element: RenderElement) -> some View {
        switch element {
        case .item(let item):
            OverlayItemView(
                item: item,
                imageCache: imageCache,
                itemManager: itemManager,
                menuBarHeight: menuBarHeight,
                spacingOffset: spacingOffset
            )
        case .thawIcon:
            if let icon = thawIconImage {
                Image(nsImage: icon)
                    .interpolation(.high)
                    .antialiased(true)
                    .padding(.horizontal, 4)
                    .frame(height: menuBarHeight)
                    .contentShape(Rectangle())
                    .overlay {
                        ThawIconClickHandler(
                            onSingleClick: onToggleHidden,
                            onDoubleClick: onShowAlwaysHidden
                        )
                    }
            }
        }
    }
}

// MARK: - OverlayItemView

private struct OverlayItemView: View {
    let item: MenuBarItem
    @ObservedObject var imageCache: MenuBarItemImageCache
    @ObservedObject var itemManager: MenuBarItemManager
    let menuBarHeight: CGFloat
    let spacingOffset: CGFloat

    private var image: NSImage? {
        imageCache.images[item.tag]?.nsImage
    }

    private func targetSize(for image: NSImage) -> CGSize {
        let intrinsic = image.size
        guard intrinsic.height > 0, menuBarHeight > 0 else { return intrinsic }
        let scale = menuBarHeight / intrinsic.height
        return CGSize(width: intrinsic.width * scale, height: menuBarHeight)
    }

    var body: some View {
        Group {
            if let image {
                let size = targetSize(for: image)
                Image(nsImage: image)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            } else if let appIcon = item.sourceApplication?.icon {
                Image(nsImage: appIcon)
                    .interpolation(.high)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 2)
                    .frame(height: menuBarHeight)
            }
        }
        .padding(.horizontal, spacingOffset / 2)
        .contentShape(Rectangle())
        .overlay {
            OverlayItemClickHandler(
                item: item,
                itemManager: itemManager
            )
        }
        .accessibilityLabel(item.displayName)
    }
}

// MARK: - OverlayItemClickHandler

/// NSView-based click handler that mirrors the user's mouse press/release
/// timing to the actual menu bar item, matching native menu bar behavior.
///
/// Native menu bar items respond to mouseDown immediately (opening their
/// menu). We forward mouseDown and mouseUp separately to preserve this
/// timing, so menus open on press and toggle correctly on repeated clicks.
private struct OverlayItemClickHandler: NSViewRepresentable {
    let item: MenuBarItem
    let itemManager: MenuBarItemManager

    /// Clicks the actual item using the Accessibility API.
    /// Finds the item's AX element through its owning app's extrasMenuBar,
    /// matching by frame proximity to the item's physical bounds.
    /// Left click uses AXPress, right click uses AXShowMenu.
    /// Forwards a click to the actual menu bar item by briefly removing
    /// the overlay from the window stack, posting a CGEvent at the item's
    /// physical position, then restoring the overlay.
    ///
    /// Each step happens on a separate RunLoop pass so the WindowServer
    /// fully processes the window removal before the event is posted.
    ///
    /// - Parameter relativeX: Where within the item the user clicked,
    ///   as a fraction 0.0 (left edge) to 1.0 (right edge). Used to
    ///   preserve click position for compound items like Alter.
    private static func forwardClick(
        button: CGMouseButton,
        item: MenuBarItem,
        relativeX: CGFloat = 0.5
    ) {
        let bounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
        // Map the user's relative click position to the physical item bounds.
        let clickPoint = CGPoint(
            x: bounds.minX + bounds.width * relativeX,
            y: bounds.midY
        )

        guard let overlay = NSApp.windows.first(where: {
            $0.title == "Thaw Item Overlay"
        }) else { return }

        // Save the user's cursor position.
        let virtualPos = CGEvent(source: nil)?.location ?? clickPoint

        // Hide cursor and make overlay pass-through.
        CGDisplayHideCursor(CGMainDisplayID())
        overlay.ignoresMouseEvents = true

        // Post mouseDown after a brief delay so WindowServer
        // processes the ignoresMouseEvents change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown

            let source = CGEventSource(stateID: .combinedSessionState)
            let downEvent = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: clickPoint,
                mouseButton: button
            )

            downEvent?.post(tap: .cghidEventTap)

            // Immediately warp cursor back and show it.
            CGAssociateMouseAndMouseCursorPosition(0)
            CGWarpMouseCursorPosition(virtualPos)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
            overlay.ignoresMouseEvents = false
        }
    }

    /// Right-click via AX showMenu — doesn't move the cursor.
    static func forwardRightClick(item: MenuBarItem) {
        DispatchQueue.global(qos: .userInteractive).async {
            let bounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
            let center = CGPoint(x: bounds.midX, y: bounds.midY)

            let pidsToTry: [pid_t] = {
                var pids = [item.ownerPID]
                if let sourcePID = item.sourcePID, sourcePID != item.ownerPID {
                    pids.append(sourcePID)
                }
                return pids
            }()

            for pid in pidsToTry {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      let axApp = AXHelpers.application(for: app),
                      let extrasBar = AXHelpers.extrasMenuBar(for: axApp)
                else { continue }

                let children = AXHelpers.children(for: extrasBar)
                var bestChild: UIElement?
                var bestDistance: CGFloat = .greatestFiniteMagnitude

                for child in children {
                    guard let frame = AXHelpers.frame(for: child) else { continue }
                    let childCenter = CGPoint(x: frame.midX, y: frame.midY)
                    let dist = hypot(center.x - childCenter.x, center.y - childCenter.y)
                    if dist < bestDistance {
                        bestDistance = dist
                        bestChild = child
                    }
                }

                if let bestChild, bestDistance < 50 {
                    if !AXHelpers.showMenu(bestChild) {
                        AXHelpers.press(bestChild)
                    }
                    return
                }
            }
        }
    }

    func makeNSView(context _: Context) -> NSView {
        Represented(item: item)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class Represented: NSView {
        let item: MenuBarItem

        init(item: MenuBarItem) {
            self.item = item
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let relX = relativeX(from: event)
            OverlayItemClickHandler.forwardClick(button: .left, item: item, relativeX: relX)
        }

        override func mouseUp(with _: NSEvent) {}

        override func rightMouseDown(with event: NSEvent) {
            let relX = relativeX(from: event)
            OverlayItemClickHandler.forwardClick(button: .right, item: item, relativeX: relX)
        }

        /// Returns the click's horizontal position as a fraction (0.0–1.0)
        /// within this view. Used to map to the physical item's bounds.
        private func relativeX(from event: NSEvent) -> CGFloat {
            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.width > 0 else { return 0.5 }
            return (localPoint.x / bounds.width).clamped(to: 0...1)
        }

        override func rightMouseUp(with _: NSEvent) {}
    }
}

// MARK: - MenuBarBackgroundPanel

/// An opaque panel that sits between the overlay and the physical menu bar items.
/// Covers the physical items so the overlay's `NSVisualEffectView` blurs
/// the desktop wallpaper (through this panel) instead of the icons.
///
/// Stack (top to bottom):
/// 1. Overlay (`.statusBar + 1`) — translucent visual effect + rendered items
/// 2. Background panel (`.statusBar`) — desktop wallpaper image, hides physical items
/// 3. Physical menu bar items (`.statusBar`) — hidden by background panel
private final class MenuBarBackgroundPanel: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        self.title = "Thaw Background"
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .moveToActiveSpace, .stationary]
        self.hidesOnDeactivate = false
        self.canHide = false
        self.ignoresMouseEvents = true

        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        self.contentView = imageView
    }

    /// Captures the system's menu bar background window, which includes
    /// the wallpaper with macOS's own tint/compositing applied. This
    /// matches the native menu bar appearance exactly regardless of
    /// wallpaper, dark/light mode, or reduce transparency settings.
    func updateWallpaper() {
        guard frame.width > 0, frame.height > 0 else { return }

        guard let screen = NSScreen.screens.first(where: {
            $0.frame.intersects(frame)
        }) else { return }

        // The WindowServer renders a dedicated "Menubar" window that
        // contains the menu bar background (wallpaper + system tint).
        // Capturing this gives us the exact native appearance.
        guard let menuBarBgWindow = WindowInfo.menuBarWindow(
            for: screen.displayID
        ) else { return }

        let menuBarHeight = frame.height
        let captureBounds = CGRect(
            x: frame.origin.x,
            y: 0,
            width: frame.width,
            height: menuBarHeight
        )

        guard let background = ScreenCapture.captureWindows(
            with: [menuBarBgWindow.windowID],
            screenBounds: captureBounds,
            option: .nominalResolution
        ) else { return }

        imageView.image = NSImage(cgImage: background, size: frame.size)
    }
}

// MARK: - ThawIconClickHandler

/// Handles clicks on the Thaw icon with immediate response on mouseDown.
/// Single click toggles hidden section, double click shows always-hidden.
private struct ThawIconClickHandler: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context _: Context) -> NSView {
        Represented(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class Represented: NSView {
        let onSingleClick: () -> Void
        let onDoubleClick: () -> Void
        private var clickCount = 0
        private var singleClickTimer: DispatchWorkItem?

        init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Option-click: show always-hidden (instant).
            if event.modifierFlags.contains(.option) {
                singleClickTimer?.cancel()
                clickCount = 0
                onDoubleClick()
                return
            }

            clickCount += 1
            singleClickTimer?.cancel()

            if clickCount >= 2 {
                clickCount = 0
                onDoubleClick()
            } else {
                let work = DispatchWorkItem { [weak self] in
                    self?.clickCount = 0
                    self?.onSingleClick()
                }
                singleClickTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }

        override func mouseUp(with _: NSEvent) {}
    }
}

// MARK: - OverlayHostingView

/// Custom hosting view that accepts first-mouse clicks in non-activating panels.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

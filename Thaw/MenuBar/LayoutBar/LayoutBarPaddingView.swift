//
//  LayoutBarPaddingView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private static let diagLog = DiagLog(category: "LayoutBarPaddingView")

    private let container: LayoutBarContainer
    private var isStabilizing = false

    private func layoutWatchdogDuration() -> Duration? {
        switch MenuBarItemManager.layoutWatchdogTimeout {
        case let .seconds(s):
            return .seconds(s)
        case let .milliseconds(ms):
            return .milliseconds(ms)
        default:
            return nil
        }
    }

    /// The layout view's arranged views.
    var arrangedViews: [LayoutBarItemView] {
        get { container.arrangedViews }
        set { container.arrangedViews = newValue }
    }

    /// Creates a layout bar view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    init(appState: AppState, section: MenuBarSection.Name) {
        self.container = LayoutBarContainer(appState: appState, section: section)

        super.init(frame: .zero)

        addSubview(container)
        self.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7.5),
            leadingAnchor.constraint(lessThanOrEqualTo: container.leadingAnchor, constant: -7.5),
        ])

        registerForDraggedTypes([.layoutBarItem])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        return container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !isStabilizing else { return }
        if let sender {
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        return container.updateArrangedViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard !isStabilizing else { return }
        container.updateArrangedViewsForDrag(with: sender, phase: .ended)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let draggingSource = sender.draggingSource as? LayoutBarItemView else {
            container.canSetArrangedViews = true
            return false
        }

        if draggingSource.item.tag == .visibleControlItem && container.section != .visible {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Cannot move \(Constants.displayName) icon.")
            alert.informativeText = String(localized: "The \(Constants.displayName) icon must always remain in the visible section.")

            if let window = window {
                alert.beginSheetModal(for: window)
            }

            // Revert the visual state: remove the item from the container it was dropped into
            // and set hasContainer to false so it snaps back to its original container.
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
            draggingSource.hasContainer = false

            container.canSetArrangedViews = true
            return false
        }

        var willMove = false

        if let index = arrangedViews.firstIndex(of: draggingSource) {
            if arrangedViews.count == 1 {
                willMove = true
                Task {
                    // dragging source is the only view in the layout bar, so we
                    // need to find a target item
                    let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
                    let targetItem: MenuBarItem? = switch container.section {
                    case .visible: nil // visible section always has more than 1 item
                    case .hidden: items.first(matching: .hiddenControlItem)
                    case .alwaysHidden: items.first(matching: .alwaysHiddenControlItem)
                    }
                    if let targetItem {
                        self.move(item: draggingSource.item, to: .leftOfItem(targetItem))
                    } else {
                        Self.diagLog.error("No target item for layout bar drag")
                        self.container.canSetArrangedViews = true
                    }
                }
            } else if arrangedViews.indices.contains(index + 1) {
                willMove = true
                // we have a view to the right of the dragging source
                let targetItem = arrangedViews[index + 1].item
                move(item: draggingSource.item, to: .leftOfItem(targetItem))
            } else if arrangedViews.indices.contains(index - 1) {
                willMove = true
                // we have a view to the left of the dragging source
                let targetItem = arrangedViews[index - 1].item
                move(item: draggingSource.item, to: .rightOfItem(targetItem))
            }
        }

        // Only re-enable view updates here if no move was initiated.
        // When a move IS initiated, the move() Task re-enables after stabilization.
        if !willMove {
            container.canSetArrangedViews = true
        }

        return true
    }

    /// Updates the virtual layout instead of physically moving the item.
    /// The overlay panel and layout pane both observe `profileManager.activeLayout`
    /// and will re-render with the new order.
    private func move(item: MenuBarItem, to destination: MenuBarItemManager.MoveDestination) {
        guard let appState = container.appState else {
            container.canSetArrangedViews = true
            return
        }

        // Build the new order from the current arranged views in this container.
        let currentOrder = container.arrangedViews.map(\.item.uniqueIdentifier)
        let targetSection = container.section
        let sectionKey: String = switch targetSection {
        case .visible: "visible"
        case .hidden: "hidden"
        case .alwaysHidden: "alwaysHidden"
        }

        // Update or create the active layout.
        var layout = appState.profileManager.activeLayout ?? MenuBarLayoutSnapshot(
            savedSectionOrder: [:],
            pinnedHiddenBundleIDs: [],
            pinnedAlwaysHiddenBundleIDs: [],
            customNames: [:]
        )

        // Update the item order for this section.
        var itemOrder = layout.itemOrder ?? [:]
        itemOrder[sectionKey] = currentOrder
        layout.itemOrder = itemOrder

        // Update the section map for the moved item.
        var sectionMap = layout.itemSectionMap ?? [:]
        sectionMap[item.uniqueIdentifier] = sectionKey
        layout.itemSectionMap = sectionMap

        // Publish the updated layout — overlay and layout pane will re-render.
        appState.profileManager.activeLayout = layout

        Self.diagLog.debug("Virtual move: \(item.logString) → \(sectionKey), order: \(currentOrder.count) items")

        container.canSetArrangedViews = true
    }
}

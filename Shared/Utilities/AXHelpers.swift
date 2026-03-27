//
//  AXHelpers.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AXSwift
import Cocoa

enum AXHelpers {
    private static let queue = DispatchQueue.targetingGlobal(
        label: "AXHelpers.queue",
        qos: .userInteractive,
        attributes: .concurrent
    )

    @discardableResult
    static func isProcessTrusted(prompt: Bool = false) -> Bool {
        queue.sync { checkIsProcessTrusted(prompt: prompt) }
    }

    static func element(at point: CGPoint) -> UIElement? {
        queue.sync { try? systemWideElement.elementAtPosition(Float(point.x), Float(point.y)) }
    }

    static func application(for runningApp: NSRunningApplication) -> Application? {
        queue.sync { Application(runningApp) }
    }

    static func menuBar(for app: Application) -> UIElement? {
        queue.sync { try? app.attribute(.menuBar) }
    }

    static func extrasMenuBar(for app: Application) -> UIElement? {
        queue.sync { try? app.attribute(.extrasMenuBar) }
    }

    static func children(for element: UIElement) -> [UIElement] {
        queue.sync { try? element.arrayAttribute(.children) } ?? []
    }

    static func isEnabled(_ element: UIElement) -> Bool {
        queue.sync { try? element.attribute(.enabled) } ?? false
    }

    static func frame(for element: UIElement) -> CGRect? {
        queue.sync { try? element.attribute(.frame) }
    }

    static func role(for element: UIElement) -> Role? {
        queue.sync { try? element.role() }
    }

    static func title(for element: UIElement) -> String? {
        queue.sync { try? element.attribute(.title) }
    }

    /// Performs the press action on the element (equivalent to left-clicking it).
    @discardableResult
    static func press(_ element: UIElement) -> Bool {
        queue.sync {
            do {
                try element.performAction(.press)
                return true
            } catch {
                return false
            }
        }
    }

    /// Performs the show-menu action on the element (equivalent to right-clicking it).
    @discardableResult
    static func showMenu(_ element: UIElement) -> Bool {
        performAction(element, action: .showMenu)
    }

    /// Performs an arbitrary action on the element.
    @discardableResult
    static func performAction(_ element: UIElement, action: Action) -> Bool {
        queue.sync {
            do {
                try element.performAction(action)
                return true
            } catch {
                return false
            }
        }
    }

    /// Returns the list of actions supported by the element.
    static func supportedActions(for element: UIElement) -> [Action] {
        queue.sync {
            guard let actionNames = try? element.actionsAsStrings() else { return [] }
            return actionNames.compactMap { Action(rawValue: $0) }
        }
    }

    /// Returns the right edge (in screen/CG coordinates) of the frontmost
    /// application's menu bar items (e.g. File, Edit, View, Help).
    /// Returns `nil` if the menu bar cannot be read.
    static func frontmostAppMenuBarMaxX() -> CGFloat? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let axApp = application(for: frontApp),
              let menuBar = menuBar(for: axApp)
        else { return nil }

        let children = children(for: menuBar)
        var maxX: CGFloat = 0
        for child in children {
            if let childFrame = frame(for: child) {
                maxX = max(maxX, childFrame.maxX)
            }
        }
        return maxX > 0 ? maxX : nil
    }
}

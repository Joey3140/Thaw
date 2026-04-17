# Thaw URI Schemes & Deep Linking

Thaw supports custom URL schemes for deep linking, enabling integration with automation tools like Raycast, Alfred, and custom scripts.

## Overview

Thaw registers the `thaw://` URL scheme in `Info.plist` via `CFBundleURLTypes`. This allows external applications and scripts to trigger Thaw actions programmatically.

## thaw:// URL Scheme

### Supported Actions

| URL                               | Action                | Description                              |
| --------------------------------- | --------------------- | ---------------------------------------- |
| `thaw://toggle-hidden`            | Toggle Hidden Section | Shows/hides the hidden menu bar section  |
| `thaw://toggle-always-hidden`     | Toggle Always-Hidden  | Shows/hides the always-hidden section    |
| `thaw://search`                   | Open Search Panel     | Displays the menu bar item search panel  |
| `thaw://toggle-thawbar`           | Toggle Thaw Bar       | Toggles the IceBar on the active display |
| `thaw://toggle-application-menus` | Toggle App Menus      | Shows/hides application menus            |
| `thaw://open-settings`            | Open Settings         | Opens the Thaw settings window           |

### Usage Examples

#### Terminal

```bash
open "thaw://toggle-hidden"
open "thaw://search"
open "thaw://open-settings"
```

#### Swift

```swift
NSWorkspace.shared.open(URL(string: "thaw://search")!)
```

#### AppleScript

```applescript
tell application "System Events"
    open location "thaw://toggle-hidden"
end tell
```

#### Bash Script

```bash
#!/bin/bash
# Toggle hidden section
open "thaw://toggle-hidden"
```

### Raycast Integration

#### Quicklink (Simple URL Trigger)

1. Open Raycast → Create Quicklink
2. Name: `Toggle Hidden Section`
3. Link: `thaw://toggle-hidden`
4. Assign a hotkey (e.g., `⌃⌥⌘H`)

#### Script Command (With Arguments)

```bash
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Thaw Actions
# @raycast.mode silent
# @raycast.argument1 { "type": "dropdown", "placeholder": "Action", "data": [{"title": "Toggle Hidden", "value": "toggle-hidden"}, {"title": "Search", "value": "search"}, {"title": "Settings", "value": "open-settings"}] }

open "thaw://${1}"
```

### Alfred Workflow

#### URL Trigger

1. Create a new Workflow
2. Add `Open URL` object
3. URL: `thaw://toggle-hidden`
4. Connect to a hotkey trigger

#### Script Filter (Advanced)

```bash
# Keyword: thaw
# Action: Toggle hidden section
open "thaw://toggle-hidden"
```

## Info.plist URLs

The following URLs are configured in `Thaw/Resources/Info.plist` for internal use:

| Key                                   | Value                                 | Description                          |
| ------------------------------------- | ------------------------------------- | ------------------------------------ |
| `ThawRepositoryURL`                   | `https://github.com/stonerl/Thaw`     | GitHub repository                    |
| `ThawDonateURL`                       | `https://github.com/sponsors/stonerl` | Sponsorship page                     |
| `ThawMenuBarItemSpacingExecutableURI` | `file:///usr/bin/env`                 | Executable path for spacing commands |

## System URLs

Thaw uses the following system URLs to open macOS Settings:

| URL                                                                             | Opens                     |
| ------------------------------------------------------------------------------- | ------------------------- |
| `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` | Screen Recording settings |

## Settings URI (Automation)

Thaw supports programmatic settings manipulation via the `thaw://` URL scheme with a security whitelist. This allows automation tools like **Droppy** to control Thaw settings.

### Security Model

1. **Feature Toggle**: Settings URI is disabled by default (enable in Settings → Automation)
2. **Whitelist**: Only approved apps can modify settings
3. **First-Time Authorization**: New apps trigger a confirmation dialog with app name and permissions
4. **Silent Failures**: Unauthorized requests fail without user interruption

### Supported Settings Keys

| Key                                       | Type | Description                                  |
| ----------------------------------------- | ---- | -------------------------------------------- |
| `autoRehide`                              | Bool | Auto-rehide hidden items after interval      |
| `showOnClick`                             | Bool | Show hidden items when clicking the menu bar |
| `showOnDoubleClick`                       | Bool | Show hidden items on double-click            |
| `showOnHover`                             | Bool | Show hidden items on hover                   |
| `showOnScroll`                            | Bool | Show hidden items on scroll                  |
| `useIceBar`                               | Bool | Enable the Thaw Bar (floating panel)         |
| `useIceBarOnlyOnNotchedDisplay`           | Bool | Thaw Bar only on Macs with notch             |
| `hideApplicationMenus`                    | Bool | Hide application menu titles                 |
| `enableAlwaysHiddenSection`               | Bool | Enable the always-hidden section             |
| `useOptionClickToShowAlwaysHiddenSection` | Bool | Option-click shows always-hidden items       |
| `enableSecondaryContextMenu`              | Bool | Right-click shows alternate menu             |
| `showAllSectionsOnUserDrag`               | Bool | Reveal all sections during drag              |
| `showMenuBarTooltips`                     | Bool | Show hover tooltips on menu bar items        |
| `enableDiagnosticLogging`                 | Bool | Enable debug logging                         |
| `customIceIconIsTemplate`                 | Bool | Custom icon renders as template              |

### Settings URL Format

#### Set a Boolean Value

```
thaw://set?key=<setting>&value=<true|false>
```

**Examples:**

```bash
# Enable auto-rehide
open "thaw://set?key=autoRehide&value=true"

# Disable hover reveal
open "thaw://set?key=showOnHover&value=false"

# Enable Thaw Bar
open "thaw://set?key=useIceBar&value=true"
```

#### Toggle a Boolean Value

```
thaw://toggle?key=<setting>
```

**Examples:**

```bash
# Toggle auto-rehide (on → off, off → on)
open "thaw://toggle?key=autoRehide"

# Toggle Thaw Bar visibility
open "thaw://toggle?key=useIceBar"

# Toggle application menu hiding
open "thaw://toggle?key=hideApplicationMenus"
```

#### Testing from Terminal (DEBUG Builds Only)

When testing from Terminal, the sender app detection may fail because `open` command doesn't properly identify the source. DEBUG builds support a manual `bundleId` override parameter:

```bash
# For testing: manually specify sender bundle ID
open "thaw://set?key=showOnHover&value=true&bundleId=com.apple.Terminal"

# This shows "Terminal" in the authorization dialog instead of "Unknown App"
```

⚠️ **DEBUG builds only:** The `bundleId` parameter is stripped/ignored in release builds for security. Always remove this parameter in production automation scripts.

### Raycast Settings Integration

```bash
#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Toggle Thaw Setting
# @raycast.mode silent
# @raycast.argument1 { "type": "dropdown", "placeholder": "Setting", "data": [{"title": "Auto-Rehide", "value": "autoRehide"}, {"title": "Hover Reveal", "value": "showOnHover"}, {"title": "Thaw Bar", "value": "useIceBar"}] }

open "thaw://toggle?key=${1}"
```

### Whitelist Management

Manage authorized apps in **Settings → Automation**:

- View all whitelisted applications with icons and names
- Remove apps to revoke their access
- Manually add bundle IDs for apps not yet authorized
- Test with Thaw itself (DEBUG builds only)

### Error Handling

Settings URI requests may fail silently in these cases:

- Settings URI feature is disabled
- Requesting app is not whitelisted (and user denied authorization)
- Invalid setting key specified
- Invalid boolean value format (not `true`/`false`/`1`/`0`/`yes`/`no`)

Check Thaw's diagnostic logs for details on failed requests.

## Notes

- All `thaw://` URLs work even when Thaw is not currently in the foreground
- The app may activate itself depending on the action
- URL handling is case-insensitive for the host portion
- Invalid URLs are logged but silently ignored
- Settings changes via URI trigger the same UI updates as manual changes

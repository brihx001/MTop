# MTop

A native macOS system monitor inspired by [btop](https://github.com/aristocratos/btop), written in SwiftUI and AppKit.

## Features

- **CPU**: total and per-core load with btop's green, yellow and red gradient, GPU usage, load average, uptime, battery
- **Memory**: the same categories as Activity Monitor (app, wired, compressed, cached, free), swap and memory pressure
- **Network**: receive and send rates for the primary interface, or the one picked from the menu
- **Disks**: live read and write throughput; available space per volume as the Finder counts it, with the purgeable part shown separately
- **Processes**: native sortable table, search, "My Processes" filter, tree view (⌥⌘T), and an inspector with per-process CPU and memory graphs. Quit, force quit, suspend or resume, after confirmation
- **Animated Dock icon**, as in Activity Monitor: **View > Dock Icon** shows CPU usage per core, GPU usage, memory (colored by memory pressure), network or disk activity, and keeps updating while the window is hidden

Sampling interval from 0.5 to 5 s, pause with ⇧⌘P. When the window is hidden or covered, MTop keeps sampling so the graphs stay complete, but stops updating the interface.

Without administrator rights, macOS does not expose the CPU and memory usage of other users' processes (root, system daemons): they show a dash.

## Installation

Download the zip from the [latest release](https://github.com/brihx001/MTop/releases/latest), unzip it and move `MTop.app` to `/Applications`.

The app is ad-hoc signed, not notarized by Apple, so macOS quarantines the download. Remove the quarantine before the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/MTop.app
```

## Building

macOS 14 or later, Swift 6.

```bash
./build.sh release
open MTop.app
```

To regenerate the icon:

```bash
cd Packaging/Icon && swift make-icon.swift . && iconutil --convert icns --output ../AppIcon.icns AppIcon.iconset
```

## License

MIT, see [LICENSE](LICENSE).

import AppKit

// Entry point. The app is a menu-bar-only agent (LSUIElement in Info.plist),
// so we also set the activation policy to .accessory at runtime — this keeps
// it out of the Dock and the cmd-tab switcher even when launched as a bare
// binary during development.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

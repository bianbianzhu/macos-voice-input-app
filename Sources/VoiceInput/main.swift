import AppKit

// Entry point. The app shows a Dock icon (.regular) so its Preferences are always
// reachable from the bottom of the screen even when the menu-bar icon is hidden
// behind the notch. It also installs a menu-bar status item; the two coexist.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

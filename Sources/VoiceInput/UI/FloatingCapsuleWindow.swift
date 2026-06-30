import AppKit
import QuartzCore

/// A borderless, non-activating HUD panel that floats near the bottom of the
/// screen while the user dictates. It hosts a live `WaveformView` on the left and
/// an elastic transcription label on the right, growing/shrinking its capsule
/// width to fit the text. The panel never becomes key/main and ignores mouse
/// events, so it can never steal focus from the app being dictated into.
///
/// Privacy note: this view only renders text it is handed; it never logs,
/// persists, or transmits anything. The transcription string lives in memory for
/// display only.
final class FloatingCapsuleWindow: NSPanel {

    // MARK: Layout constants

    private let capsuleHeight: CGFloat = 56
    private let capsuleCornerRadius: CGFloat = 28
    private let waveformWidth: CGFloat = 44
    private let waveformHeight: CGFloat = 32
    private let leftPadding: CGFloat = 18
    private let rightPadding: CGFloat = 18
    private let interGap: CGFloat = 10
    private let minTextWidth: CGFloat = 160
    private let maxTextWidth: CGFloat = 560
    private let textMeasureInset: CGFloat = 14
    private let bottomInset: CGFloat = 120

    // MARK: Animation timings

    private let entryDuration: CFTimeInterval = 0.35
    private let widthDuration: TimeInterval = 0.25
    private let exitDuration: CFTimeInterval = 0.22
    private let entryStartScale: CGFloat = 0.9
    private let exitEndScale: CGFloat = 0.92

    // MARK: Content

    private let effectView = NSVisualEffectView()
    private let waveform = WaveformView()
    private let label = NSTextField(labelWithString: "")
    private let labelFont = NSFont.systemFont(ofSize: 15, weight: .medium)

    // MARK: State

    /// Shown when there is no transcript yet (e.g. "Listening…"/"Refining…").
    private var placeholder: String = ""
    /// The latest transcript text (display only; never logged or persisted).
    private var currentText: String = ""
    /// Screen rect captured when the capsule appears, so width animations recenter
    /// against a stable anchor even if the mouse later moves to another display.
    private var anchorScreenFrame: NSRect = .zero

    /// Pending auto-dismiss for a transient `showStatus` message. Held so a new
    /// dictation cycle (`showListening`) or an explicit `dismiss` can cancel it and
    /// a stale scheduled dismissal can never clobber the next cycle (same defensive
    /// pattern as `TextInjector`'s cancellable pending restores).
    private var pendingStatusDismiss: DispatchWorkItem?

    // MARK: Status kinds

    /// Distinguishes a corrective error notice from a neutral informational one,
    /// purely so the label can carry the right leading glyph. The glyphs use the
    /// text-presentation variation selector (U+FE0E) to stay monochrome and match
    /// the menu's existing `⚠︎` rather than rendering as a color emoji.
    enum StatusKind {
        case error
        case info

        var glyph: String {
            switch self {
            case .error: return "\u{26A0}\u{FE0E}" // ⚠︎
            case .info: return "\u{2139}\u{FE0E}"  // ℹ︎
            }
        }
    }

    // MARK: Init

    init() {
        let initialRect = NSRect(x: 0, y: 0, width: 250, height: 56)
        super.init(contentRect: initialRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        configurePanel()
        configureContent()
    }

    /// Required by `NSCoding`; this panel is only ever created programmatically,
    /// so decoding is unsupported (`NSWindow.init(coder:)` is unavailable).
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported; create FloatingCapsuleWindow programmatically")
    }

    // MARK: Focus suppression

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Public API

    /// Show the capsule centered at the bottom of the main screen with the entry
    /// spring animation. Resets text to empty and the status to the listening copy
    /// for `language` (the locale being transcribed).
    func showListening(language: String) {
        // A new cycle supersedes any pending status auto-dismiss from the prior one.
        pendingStatusDismiss?.cancel()
        pendingStatusDismiss = nil

        placeholder = L10n.listening(language)
        currentText = ""

        waveform.startAnimating()
        waveform.setLevel(0)

        anchorScreenFrame = currentScreenFrame()
        label.stringValue = placeholder
        setFrame(targetFrame(forContentWidth: contentWidth(for: placeholder)), display: true)

        // Prime the layer for the entry animation.
        contentView?.layoutSubtreeIfNeeded()
        anchorContentLayerToCenter()
        let layer = contentView?.layer
        layer?.removeAllAnimations()
        layer?.transform = CATransform3DIdentity
        alphaValue = 0

        // Non-activating: appear without ever stealing focus from the target app.
        orderFrontRegardless()

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = entryStartScale
        spring.toValue = 1.0
        spring.mass = 1
        spring.stiffness = 220
        spring.damping = 14
        spring.initialVelocity = 0
        spring.duration = entryDuration
        spring.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(spring, forKey: "entry")

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = entryDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Update the live transcription text; the capsule width animates within the
    /// 160...560 text band, recentering on the bottom of the anchored screen.
    func updateText(_ text: String) {
        currentText = text
        let display = text.isEmpty ? placeholder : text
        label.stringValue = display
        animateFrame(to: targetFrame(forContentWidth: contentWidth(for: display)))
    }

    /// Forward an audio level (0...1) to the waveform. Caller hops to MAIN thread.
    func updateLevel(_ level: Float) {
        waveform.setLevel(level)
    }

    /// Switch the status line to the refining copy for `language`, keeping visible.
    func showRefining(language: String) {
        let display = L10n.refining(language)
        placeholder = display
        currentText = ""
        label.stringValue = display
        animateFrame(to: targetFrame(forContentWidth: contentWidth(for: display)))
    }

    /// Show a brief, terminal status/error in the ALREADY-VISIBLE capsule: stop the
    /// waveform, swap to a glyph-prefixed message, then auto-dismiss after `seconds`.
    /// Precondition: the capsule is on-screen at both call sites (recording-start
    /// failure and LLM fallback), so no entry/re-entry animation is needed here.
    ///
    /// The pending dismissal is cancellable so a new dictation cycle (`showListening`)
    /// or an explicit `dismiss` can supersede it without a stale timer double-dismissing.
    /// Privacy: `message` is always static localized copy — never a transcript, key,
    /// URL, app name, or `error.localizedDescription`.
    func showStatus(_ message: String, kind: StatusKind, autoDismissAfter seconds: TimeInterval) {
        pendingStatusDismiss?.cancel()
        waveform.stopAnimating()

        let display = "\(kind.glyph) \(message)"
        placeholder = display
        currentText = ""
        label.stringValue = display
        animateFrame(to: targetFrame(forContentWidth: contentWidth(for: display)))

        let work = DispatchWorkItem { [weak self] in self?.dismiss(completion: nil) }
        pendingStatusDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Exit scale + fade animation, then `orderOut`. Invokes `completion` on the
    /// main thread once the panel is fully hidden and reset for reuse.
    func dismiss(completion: (() -> Void)?) {
        // An explicit dismiss owns the teardown; drop any pending status auto-dismiss
        // so it can't fire a second time against a freshly reused capsule.
        pendingStatusDismiss?.cancel()
        pendingStatusDismiss = nil

        anchorContentLayerToCenter()
        let layer = contentView?.layer

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = exitEndScale
        scale.duration = exitDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        layer?.add(scale, forKey: "exit")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = self.exitDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            self.waveform.stopAnimating()
            self.orderOut(nil)
            // Reset for the next presentation.
            self.contentView?.layer?.removeAllAnimations()
            self.contentView?.layer?.transform = CATransform3DIdentity
            self.alphaValue = 1
            completion?()
        })
    }

    // MARK: Configuration

    private func configurePanel() {
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Pure HUD: no document/file proxy, never participates in window cycling.
        animationBehavior = .none
    }

    /// A resizable capsule-shaped mask for the visual-effect view. Cap insets make
    /// it stretch cleanly as the capsule widens with the text.
    private static func capsuleMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    private func configureContent() {
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = capsuleCornerRadius
        effectView.layer?.masksToBounds = true
        // layer.cornerRadius clips subviews but NOT the vibrancy backdrop, so on a
        // light background the material's full rectangle (and the window's
        // rectangular shadow) would show as a white box. A resizable rounded mask
        // image clips the material itself to the capsule shape; the window shadow
        // then follows that shape too.
        effectView.maskImage = FloatingCapsuleWindow.capsuleMask(cornerRadius: capsuleCornerRadius)
        // Keep the HUD dark regardless of the system appearance, so the white
        // waveform and text stay legible on any background.
        effectView.appearance = NSAppearance(named: .darkAqua)
        contentView = effectView

        label.font = labelFont
        label.textColor = .white
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .left
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingHead
        label.cell?.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byTruncatingHead
        // The window owns the width; let the label truncate rather than force-resize.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        waveform.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(waveform)
        effectView.addSubview(label)

        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: leftPadding),
            waveform.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: waveformWidth),
            waveform.heightAnchor.constraint(equalToConstant: waveformHeight),

            label.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: interGap),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -rightPadding),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor)
        ])
    }

    // MARK: Geometry helpers

    /// Frame of the screen the capsule should anchor to.
    private func currentScreenFrame() -> NSRect {
        if let main = NSScreen.main { return main.frame }
        if let first = NSScreen.screens.first { return first.frame }
        return NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Total capsule width for the given display string, clamping the text band to
    /// 160...560 per the contract:
    /// width = leftPadding + waveform + gap + clamp(textWidth, 160, 560) + rightPadding.
    private func contentWidth(for display: String) -> CGFloat {
        let measured = (display as NSString).size(withAttributes: [.font: labelFont]).width
        let textBand = min(maxTextWidth, max(minTextWidth, ceil(measured) + textMeasureInset))
        return leftPadding + waveformWidth + interGap + textBand + rightPadding
    }

    /// A capsule-sized frame centered horizontally and floated `bottomInset` above
    /// the bottom of the anchored screen.
    private func targetFrame(forContentWidth width: CGFloat) -> NSRect {
        let anchor = anchorScreenFrame == .zero ? currentScreenFrame() : anchorScreenFrame
        let originX = anchor.midX - width / 2
        let originY = anchor.minY + bottomInset
        return NSRect(x: originX, y: originY, width: width, height: capsuleHeight)
    }

    /// Animate the panel to `target` over the width-change duration, skipping work
    /// when the change is negligible.
    private func animateFrame(to target: NSRect) {
        let current = frame
        if abs(target.width - current.width) < 0.5 && abs(target.origin.x - current.origin.x) < 0.5 {
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = widthDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }
    }

    /// Ensure the content layer scales about its center. Sets the anchor point to
    /// (0.5, 0.5) and compensates position so the visible frame does not shift.
    /// Idempotent: a no-op once already centered (AppKit keeps `position` in sync
    /// with the frame for the current anchor point on subsequent resizes).
    private func anchorContentLayerToCenter() {
        guard let layer = contentView?.layer else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        if layer.anchorPoint == center { return }
        let oldFrame = layer.frame
        layer.anchorPoint = center
        layer.position = CGPoint(x: oldFrame.midX, y: oldFrame.midY)
    }
}

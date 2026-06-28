import AppKit

/// A compact five-bar audio "waveform" indicator for the floating capsule HUD.
///
/// The view draws five vertical, rounded-cap bars inside a fixed 44 x 32 box. Bar
/// heights are driven by a normalized audio level (0...1) fed in via `setLevel`,
/// shaped per-bar by fixed weights and smoothed with an asymmetric attack/release
/// envelope plus a touch of random jitter so the meter feels organic rather than
/// mechanical. A ~60fps timer on the main run loop advances the animation.
///
/// This view never touches audio samples, transcribed text, or keystrokes — it only
/// receives an already-normalized scalar level — so there is nothing sensitive to log.
final class WaveformView: NSView {

    // MARK: Visual constants

    /// Fixed intrinsic size of the indicator, in points.
    private static let boxSize = NSSize(width: 44, height: 32)

    /// Width of each bar, in points.
    private static let barWidth: CGFloat = 5
    /// Horizontal gap between adjacent bars, in points.
    private static let barGap: CGFloat = 4
    /// Floor height so bars remain visible even when the signal is silent.
    private static let minBarHeight: CGFloat = 3

    /// Per-bar amplitude weighting — center bar tallest, tapering outward.
    private static let weights: [Float] = [0.5, 0.8, 1.0, 0.75, 0.55]

    // MARK: Envelope constants

    /// Smoothing coefficient applied while a bar is rising toward its target.
    private static let attack: Float = 0.40
    /// Smoothing coefficient applied while a bar is falling toward its target.
    private static let release: Float = 0.15
    /// Maximum per-tick random jitter (±4%).
    private static let jitter: Float = 0.04
    /// Animation tick rate (~60fps).
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    // MARK: State

    /// The CALayers that render the bars, one per weight.
    private var barLayers: [CALayer] = []
    /// Current smoothed amplitude per bar, normalized 0...1.
    private var values: [Float]
    /// Latest target level supplied by `setLevel`, normalized 0...1.
    private var targetLevel: Float = 0
    /// The animation driver. Block-based with a weak self capture so the view can
    /// deinit cleanly without an explicit invalidate by the owner.
    private var displayTimer: Timer?

    // MARK: Init

    init() {
        self.values = Array(repeating: 0, count: WaveformView.weights.count)
        super.init(frame: NSRect(origin: .zero, size: WaveformView.boxSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupBarLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WaveformView is not designed to be loaded from a nib")
    }

    deinit {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: Layout

    override var intrinsicContentSize: NSSize {
        WaveformView.boxSize
    }

    override var isFlipped: Bool {
        // Use a top-left-free, bottom-left origin; bars are vertically centered so
        // orientation is cosmetic, but being explicit keeps layer math predictable.
        false
    }

    override func layout() {
        super.layout()
        renderBars()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Keep the rounded caps crisp on Retina displays.
        let scale = window?.backingScaleFactor ?? 2.0
        for bar in barLayers {
            bar.contentsScale = scale
        }
    }

    // MARK: Public API (MAIN thread)

    /// Sets the target amplitude (0...1) for the meter. Called on the main thread.
    /// Values outside the unit range are clamped.
    func setLevel(_ level: Float) {
        if level.isNaN {
            targetLevel = 0
        } else {
            targetLevel = min(1, max(0, level))
        }
    }

    /// Starts the animation timer. Safe to call repeatedly.
    func startAnimating() {
        guard displayTimer == nil else { return }
        // Begin from a calm baseline so the entry feels consistent each time.
        targetLevel = 0
        for i in values.indices { values[i] = 0 }
        renderBars()

        let timer = Timer(timeInterval: WaveformView.frameInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the meter keeps animating during event tracking / modal loops.
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Stops the animation timer and lets the bars rest at their floor height.
    func stopAnimating() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: Internals

    private func setupBarLayers() {
        guard let root = layer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        for _ in WaveformView.weights {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = WaveformView.barWidth / 2
            bar.contentsScale = scale
            // We drive every frame manually; suppress implicit animations entirely.
            bar.actions = ["position": NSNull(),
                           "bounds": NSNull(),
                           "frame": NSNull(),
                           "cornerRadius": NSNull()]
            root.addSublayer(bar)
            barLayers.append(bar)
        }
        renderBars()
    }

    /// Advances the envelope one frame and redraws.
    private func tick() {
        let weights = WaveformView.weights
        for i in values.indices {
            let target = targetLevel * weights[i]
            let coeff: Float = target > values[i] ? WaveformView.attack : WaveformView.release
            var v = values[i] + (target - values[i]) * coeff
            v *= 1 + Float.random(in: -WaveformView.jitter...WaveformView.jitter)
            // Clamp to the normalized range to keep the envelope bounded.
            values[i] = min(1, max(0, v))
        }
        renderBars()
    }

    /// Positions and sizes every bar layer from the current `values`, vertically
    /// centered within the box. Implicit layer animations are disabled so updates
    /// land exactly on the animation tick.
    private func renderBars() {
        guard !barLayers.isEmpty else { return }

        let barWidth = WaveformView.barWidth
        let gap = WaveformView.barGap
        let count = CGFloat(barLayers.count)
        let totalWidth = barWidth * count + gap * (count - 1)
        let boxWidth = bounds.width
        let boxHeight = bounds.height
        let startX = ((boxWidth - totalWidth) / 2).rounded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in barLayers.indices {
            let normalized = CGFloat(values[i])
            let height = min(boxHeight, max(WaveformView.minBarHeight, normalized * boxHeight))
            let x = startX + CGFloat(i) * (barWidth + gap)
            let y = ((boxHeight - height) / 2).rounded()
            barLayers[i].frame = CGRect(x: x, y: y, width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}

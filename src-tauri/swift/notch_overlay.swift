// Native notch overlay: a CALayer island driven by CASpringAnimation.
// Rust decides when it shows and what it says (C entry points at the bottom,
// all hopping to the main thread); this file decides how it looks and moves.

import AppKit
import QuartzCore
import CoreImage
import CoreAudio
import AudioToolbox
import SwiftUI

// MARK: - Geometry

/// The island has three sizes. `closed` is the housing itself, invisible at
/// rest. `peek` is the hover acknowledgement — a small lift that says "I'm
/// here" without opening — and `open` is recording, with the chin content.
enum IslandState {
    case closed, peek, open
    /// Clicked: the full notes list, tall and wide.
    case expanded
}

/// What the open island is showing. Same shape; content and tint differ.
enum IslandMode: Equatable {
    case dictate
    case instruct
    /// The refine key was tapped once: the island acknowledges — sparkle,
    /// "Refine / double-tap to describe a change instead" — and waits out the tap window
    /// to see whether a hold follows (→ instruct) or not (→ working).
    case armed
    /// Label plus the SF Symbol that says which kind of work: transcribing
    /// shows lines of text (speech becoming text — not a waveform, which now
    /// means recording), refining the sparkle.
    case working(String, symbol: String)
    /// Outcome shown for a beat before closing. `label` is what it says
    /// ("Done", "Noted", "Couldn't do that").
    case done(ok: Bool, label: String)
    /// The notes list is showing (expanded state); the chin cluster is empty.
    case notes
    /// The track changed: a brief banner under the housing — artwork and
    /// bars stay in the top band, "Title · Artist" beneath (the iPhone
    /// island's song-change moment). Auto-closes.
    case announce(title: String, artist: String)

    var isAnnounce: Bool { if case .announce = self { return true }; return false }

    var isDone: Bool { if case .done = self { return true }; return false }
    var isSuccess: Bool { if case .done(let ok, _) = self { return ok }; return false }

    var isRecording: Bool { self == .dictate || self == .instruct }
}

/// Numbers follow boring.notch / DynamicNotchKit, checked against the HIG.
private enum Island {
    /// Chin below the housing, per state. Closed is exactly the housing so
    /// the pill is invisible at rest.
    static func chinHeight(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 0; case .peek: 8; case .open: 62; case .expanded: 300 }
    }
    /// Extension past the cutout per side. Closed keeps 2pt of slop so the
    /// bezel seam never shows a light gap.
    static func overhang(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 2; case .peek: 10; case .open: 58; case .expanded: 120 }
    }
    /// Concave fillet where the island meets the screen edge — what makes it
    /// an island rather than a pill. Both radii scale with the state.
    static func flare(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 6; case .peek: 10; case .open: 22; case .expanded: 24 }
    }
    /// Bottom corner radius. Open = flare + 5, the ratio the reference apps use.
    static func cornerRadius(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 14; case .peek: 17; case .open: 28; case .expanded: 32 }
    }
    /// Shadow only once lifted: at rest the island must read as hardware, and
    /// hardware does not cast a shadow onto the wallpaper.
    static func shadowOpacity(_ s: IslandState) -> Float {
        switch s { case .closed: 0; case .peek: 0.4; case .open: 0.7; case .expanded: 0.8 }
    }

    /// Springs as Apple specifies them (WWDC23 "Animate with springs"):
    /// perceptual duration + bounce, converted to CA's mass/stiffness/damping.
    /// Growing carries a small bounce so it reads as physical; shrinking is
    /// nearly critically damped — a bounce on the way shut looks indecisive.
    static let growDuration: CFTimeInterval = 0.55
    static let growBounce: CGFloat = 0.15
    /// Expanding to a card is the big move; it gets a visibly springy landing.
    static let expandDuration: CFTimeInterval = 0.6
    static let expandBounce: CGFloat = 0.28
    /// Peek moves a few points; on the open spring it feels like lag.
    static let peekDuration: CFTimeInterval = 0.3
    static let peekBounce: CGFloat = 0.25
    static let shrinkDuration: CFTimeInterval = 0.5
    /// A hint of bounce on the way shut — enough that the collapse reads as
    /// the island settling into the housing, not enough to look indecisive.
    static let shrinkBounce: CGFloat = 0.08
    /// Content appears a beat after the shape starts moving, once there is
    /// room for it, and leaves a beat before the shape shrinks. Both are what
    /// separates a morph from a pop.
    static let contentInDelay: CFTimeInterval = 0.14
    static let contentInDuration: CFTimeInterval = 0.34
    static let contentOutDuration: CFTimeInterval = 0.32
    static let contentOutLead: CFTimeInterval = 0.06
    /// Content blurs as it leaves, the way iOS island content does.
    static let contentOutBlur: CGFloat = 8

    /// Hover: dwell before the peek, grace after the pointer leaves, and how
    /// far outside the pill still counts as "on it" (larger once lifted so a
    /// pointer drifting along the edge doesn't flicker it).
    static let hoverDwell: TimeInterval = 0.12
    static let hoverExitGrace: TimeInterval = 0.15
    static func hoverSlop(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 10; case .peek, .open, .expanded: 30 }
    }
}

/// stiffness = (2π/d)², damping = 4π(1−bounce)/d, mass 1 — Apple's formulas.
private func springAnimation(keyPath: String, duration: CFTimeInterval, bounce: CGFloat) -> CASpringAnimation {
    let spring = CASpringAnimation(keyPath: keyPath)
    spring.mass = 1
    spring.stiffness = pow(2 * .pi / duration, 2)
    spring.damping = 4 * .pi * (1 - bounce) / duration
    spring.initialVelocity = 0
    // CA snaps to the final value when `duration` elapses, so the animation
    // must run to settle. The perceptual duration governs when we ORDER OUT
    // (Apple: don't wait for settling), not how long the layer animates.
    spring.duration = spring.settlingDuration
    return spring
}

/// The island outline, centred: x in -w/2...w/2, y in 0 (bottom)...h (top).
/// Every layer uses this frame anchored at top-centre, so no position depends
/// on the current width and nothing can drift while the bounds spring.
private func islandPath(
    size: CGSize, cornerRadius r: CGFloat, flare f: CGFloat,
    topRadius t: CGFloat = 0, topInset i: CGFloat = 0, closed: Bool = true
) -> CGPath {
    let raw = islandPathLeftOrigin(size: size, cornerRadius: r, flare: f, topRadius: t, topInset: i, closed: closed)
    var shift = CGAffineTransform(translationX: -size.width / 2, y: 0)
    return raw.copy(using: &shift) ?? raw
}

/// Centred bounds for a pill of `size`, top-centre anchored.
private func islandBounds(_ size: CGSize) -> CGRect {
    CGRect(x: -size.width / 2, y: 0, width: size.width, height: size.height)
}

/// One path grammar for two shapes, so CA can spring between them:
/// - Notch: square top corners on the screen edge, concave `flare` fillets
///   into the walls, round bottom corners (`cornerRadius`).
/// - Free-floating pill (screens without a housing, at rest): convex top
///   corners of `topRadius`, top edge `topInset` below the screen edge,
///   no flares. With `topRadius == 0` and `topInset == 0` it is the
///   attached box the virtual island opens into.
/// Element sequence is identical in every case — move, curve, line, curve,
/// line, curve, line, curve, close — which is what path animation requires.
///
/// `closed: false` leaves out the top edge — the segment along the screen
/// edge — for stroking: the fill needs it, but a key line drawn there is a
/// seam between the island and the housing, and lightens the island's top so
/// it no longer matches the notch's black.
private func islandPathLeftOrigin(
    size: CGSize, cornerRadius r: CGFloat, flare f: CGFloat,
    topRadius t: CGFloat, topInset i: CGFloat, closed: Bool
) -> CGPath {
    let w = size.width
    let h = size.height - i
    let path = CGMutablePath()
    let kappa: CGFloat = 0.5523

    // Top-left: either the flare's start on the screen edge (t == 0) or the
    // pill's rounded corner (f == 0). Only one of f, t is ever non-zero.
    let tlStart = CGPoint(x: t, y: h)
    let tlEnd = CGPoint(x: f, y: h - f - t)
    path.move(to: tlStart)
    if t > 0 {
        let k = kappa * t
        path.addCurve(to: tlEnd, control1: CGPoint(x: t - k, y: h), control2: CGPoint(x: 0, y: h - t + k))
    } else {
        // Concave fillet as a cubic: the quad with control (f, h), lifted.
        let c = CGPoint(x: f, y: h)
        path.addCurve(
            to: tlEnd,
            control1: CGPoint(x: tlStart.x + (c.x - tlStart.x) * 2 / 3, y: tlStart.y + (c.y - tlStart.y) * 2 / 3),
            control2: CGPoint(x: tlEnd.x + (c.x - tlEnd.x) * 2 / 3, y: tlEnd.y + (c.y - tlEnd.y) * 2 / 3)
        )
    }
    // Left wall.
    path.addLine(to: CGPoint(x: f, y: r))
    // Bottom corners are true circular arcs (cubic, kappa) — a quad curve is
    // a parabola, visibly flat once the radius grows.
    let k = kappa * r
    path.addCurve(
        to: CGPoint(x: f + r, y: 0),
        control1: CGPoint(x: f, y: r - k),
        control2: CGPoint(x: f + r - k, y: 0)
    )
    // Bottom edge.
    path.addLine(to: CGPoint(x: w - f - r, y: 0))
    path.addCurve(
        to: CGPoint(x: w - f, y: r),
        control1: CGPoint(x: w - f - r + k, y: 0),
        control2: CGPoint(x: w - f, y: r - k)
    )
    // Right wall.
    let trStart = CGPoint(x: w - f, y: h - f - t)
    let trEnd = CGPoint(x: w - t, y: h)
    path.addLine(to: trStart)
    if t > 0 {
        let k = kappa * t
        path.addCurve(to: trEnd, control1: CGPoint(x: w, y: h - t + k), control2: CGPoint(x: w - t + k, y: h))
    } else {
        let c = CGPoint(x: w - f, y: h)
        path.addCurve(
            to: trEnd,
            control1: CGPoint(x: trStart.x + (c.x - trStart.x) * 2 / 3, y: trStart.y + (c.y - trStart.y) * 2 / 3),
            control2: CGPoint(x: trEnd.x + (c.x - trEnd.x) * 2 / 3, y: trEnd.y + (c.y - trEnd.y) * 2 / 3)
        )
    }
    if closed { path.closeSubpath() }
    return path
}

private final class IslandView: NSView {
    let pill = CAShapeLayer()
    /// Shadow lives under the pill on its own layer: the pill clips contents,
    /// so it would clip its own shadow.
    private let shadowLayer = CALayer()
    /// Hairline light along the pill's edge, drawn above the contents.
    private let rim = CAShapeLayer()
    /// Now Playing at rest: a tiny artwork left of the housing and four
    /// dancing bars right of it (Alcove / iPhone island). Only while closed
    /// or peeking with media available and nothing being recorded.
    private let miniArt = CALayer()
    private let miniBars: [CAShapeLayer] = (0..<4).map { _ in CAShapeLayer() }
    private var mediaAvailable = false
    private var mediaPlaying = false
    private var barsAccent: CGColor = NSColor.white.cgColor
    /// Sound HUD: icon + "Sound" left of the housing, meter + value right.
    /// Shown briefly when the system volume changes; wins over the media
    /// mini while up.
    private let hudIcon = CALayer()
    private let hudLabel = CATextLayer()
    private let hudTrack = CAShapeLayer()
    private let hudFill = CAShapeLayer()
    private let hudValue = CATextLayer()
    private(set) var hudActive = false
    private var hudLevel: Float = 0
    private var hudIconName = "speaker.wave.2.fill"
    private static let hudExtra: CGFloat = 104
    private static let hudGreen = NSColor(red: 0.42, green: 0.83, blue: 0.6, alpha: 1)

    private static let miniSize: CGFloat = 20
    private static let miniPad: CGFloat = 6
    /// Whether the bars are currently animating (avoid restarting them on
    /// every update — a restart snaps the phase and shifts pixels).
    private var barsDancing = false
    /// Extra pill width per side while the media pill shows.
    private var mediaExtra: CGFloat { Self.miniSize + Self.miniPad * 2 - Island.overhang(.closed) }
    private func mediaPill(_ s: IslandState) -> Bool {
        if yielding || !mediaAvailable || hudActive { return false }
        // The banner keeps the artwork and bars in its top band.
        if s == .open, mode.isAnnounce { return true }
        return s == .closed || s == .peek
    }
    /// Clips everything inside the pill to the island outline, and rides
    /// the same spring, so content is revealed BY the shape opening — it
    /// cannot be seen where the island has not yet grown. Without this the
    /// wave and timer floated in before the chin existed.
    private let clip = CAShapeLayer()
    /// Everything in the chin. Fades and scales in from the top edge as one
    /// unit, so content is revealed by the island opening rather than popping.
    private let content = CALayer()
    /// Siri-style layered wave (after alfianlosari/SiriWaveView): three
    /// translucent sine composites, paths rebuilt on a 30 Hz tick with a
    /// fixed point count so they morph.
    private var waveLayers: [CAShapeLayer] = []
    private var waveShapes: [SiriWave] = []
    private var waveTargets: [SiriWave] = []
    private var wavePower: CGFloat = 0
    private var wavePowerTarget: CGFloat = 0
    private var waveTick: Timer?
    private var waveRect: CGRect = .zero
    private var lastReroll: TimeInterval = 0
    /// Elapsed time, right of the wave, as Voice Memos pairs them. Digits
    /// are monospaced so the label doesn't jitter as they tick.
    private let timer = CATextLayer()
    /// SF Symbol glyphs for the non-dictation modes: sparkles for instruct
    /// and working, a check or an x for done.
    private let symbol = CALayer()
    /// The completion mark: a green disc that pops in and a white check that
    /// draws itself on — Apple's own completion gesture (Apple Pay, Shortcuts),
    /// not a static glyph.
    private let checkDisc = CAShapeLayer()
    private let checkStroke = CAShapeLayer()
    /// Status text for working/done ("Refining…", "Done").
    private let label = CATextLayer()
    /// Second, smaller line under the label for the refine hints ("press
    /// again to describe a change"); empty in the other modes.
    private let sublabel = CATextLayer()
    /// Halo behind the sparkle for the armed acknowledgement: a soft lavender
    /// disc that blooms once as the sparkle pops in.
    private let halo = CALayer()
    /// A band of light sweeping through the working label — the system's
    /// "thinking" shimmer — so a wait reads as alive rather than stuck.
    private let shimmer = CAGradientLayer()
    private(set) var mode: IslandMode = .dictate
    /// The notes list (SwiftUI) shown in the expanded state. An NSView, so it
    /// sits above the layers; faded in once the shape has grown.
    let notesModel = NotesModel()
    let mediaModel = NowPlayingModel()
    /// Which card the expanded island shows; the player when something is
    /// playing, else the inbox. The user can flip it from the card.
    let expandedTab = ExpandedTab()
    private var notesHostView: NSView?
    /// Created on first use; nil before macOS 14 (no notch Mac runs that).
    private var notesHost: NSView? {
        if let notesHostView { return notesHostView }
        guard #available(macOS 14.0, *) else { return nil }
        let h = NSHostingView(rootView: ExpandedView(notes: notesModel, media: mediaModel, tab: expandedTab))
        h.alphaValue = 0
        h.isHidden = true
        addSubview(h)
        notesHostView = h
        return h
    }
    /// User setting: show the small clock once a dictation runs long.
    var clockEnabled = true
    private var timerTick: Timer?
    private var recordingStart: Date?
    private enum Wave {
        static let totalWidth: CGFloat = 196
        /// Narrower beside the "Describe your change" hint.
        static let instructWidth: CGFloat = 120
        static let maxHeight: CGFloat = 46
        /// Points per wave path; constant so paths morph.
        static let samples = 48
        /// How often each layer picks a new random composition.
        static let rerollInterval: TimeInterval = 0.3
        /// A whisper of motion at silence, so the wave reads as listening.
        static let idlePower: CGFloat = 0.06
    }
    /// The three wave colours per mode: brand blues for dictation, lavender
    /// for an instruction, so the two still read differently at a glance.
    private enum WavePalette {
        static let dictate: [NSColor] = [
            NSColor(red: 0.44, green: 0.66, blue: 0.86, alpha: 0.85),
            NSColor(red: 0.62, green: 0.77, blue: 0.91, alpha: 0.75),
            NSColor(red: 0.90, green: 0.96, blue: 1.00, alpha: 0.65),
        ]
        static let instruct: [NSColor] = [
            NSColor(red: 0.62, green: 0.50, blue: 0.92, alpha: 0.85),
            NSColor(red: 0.76, green: 0.66, blue: 0.96, alpha: 0.75),
            NSColor(red: 0.94, green: 0.90, blue: 1.00, alpha: 0.65),
        ]
    }
    private enum Text {
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        static let width: CGFloat = 40
        /// The clock is small and only appears once a dictation runs long
        /// enough that "am I still recording?" becomes a real question.
        static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        static let clockWidth: CGFloat = 34
        static let clockAfter: TimeInterval = 8
        /// Two-line hint for the refine gesture: title + quieter sub.
        static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let subFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    }
    private enum Tint {
        /// Voice Memos red.
        static let dictate = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
        /// The brand accent — a light steel blue — for anything that is the
        /// assistant rather than the recording.
        static let instruct = NSColor(red: 0.76, green: 0.66, blue: 0.96, alpha: 1)
        static let ok = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        static let fail = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    }
    private enum Glyph {
        static let symbolSize: CGFloat = 20
    }
    /// Space between glyph, wave and timer. The three are laid out as one
    /// centred cluster — content pinned to opposite walls read as two
    /// unrelated things.
    private static let clusterGap: CGFloat = 14

    /// Level history for the voice-memo waveform: newest sample on the right,
    /// scrolling left as speech continues — the shape of what was just said,
    /// not merely the current loudness.

    private var cutoutWidth: CGFloat = 186
    private var safeAreaTop: CGFloat = 32
    /// The expanded chin depends on what it shows: the player card is
    /// shorter than the notes list. Set before layoutPill(.expanded).
    var expandedChin: CGFloat = Island.chinHeight(.expanded)
    var expandedOverhang: CGFloat = Island.overhang(.expanded)
    private func chinHeight(_ s: IslandState) -> CGFloat {
        if s == .expanded { return expandedChin }
        // The song banner is shallower than a full open.
        if s == .open, mode.isAnnounce { return 46 }
        return Island.chinHeight(s)
    }
    /// No hardware housing on this screen: draw nothing at rest.
    private var synthetic = false
    /// Another notch app owns the resting state; we draw nothing closed.
    private var yielding = false
    func setYielding(_ y: Bool) {
        yielding = y
        if state == .closed { layoutPill(.closed, animated: false) }
    }
    /// Backing scale of the screen the island is on.
    private var contentScale: CGFloat = 2
    private(set) var state: IslandState = .closed

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        // Pure black to fuse with the housing; shape comes from the path.
        pill.fillColor = NSColor.black.cgColor
        pill.backgroundColor = NSColor.clear.cgColor

        // Shadow on its own layer under the pill (the pill masks its own
        // contents), and only when open — at rest it must read as hardware.
        shadowLayer.backgroundColor = NSColor.clear.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0
        shadowLayer.shadowRadius = 10
        shadowLayer.shadowOffset = CGSize(width: 0, height: -5) // downward, y-up space
        layer?.addSublayer(shadowLayer)

        // Pill and shadow hang from the view's top-centre; mask and rim are
        // anchored bottom-centre at (0, 0) so their bounds track the pill's.
        for l in [pill, shadowLayer] as [CALayer] {
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
        }
        for l in [clip, rim] as [CALayer] {
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
        }

        clip.fillColor = NSColor.black.cgColor
        pill.mask = clip

        // The HIG key line: on a dark desktop a pure-black island vanishes
        // into the wallpaper and the menu bar; a hairline of light along its
        // edge is what separates it. Drawn just inside the outline so the
        // flares keep their crisp meeting with the screen edge.
        rim.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        rim.lineWidth = 1
        rim.lineCap = .butt
        rim.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(pill)

        content.anchorPoint = CGPoint(x: 0.5, y: 1) // scale from the housing edge
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            content.filters = [blur]
        }
        content.opacity = 0
        pill.addSublayer(content)

        for _ in 0..<3 {
            let wave = CAShapeLayer()
            wave.lineWidth = 0
            // Screen-blend so overlaps go lighter, the way stacked light does.
            wave.compositingFilter = "screenBlendMode"
            content.addSublayer(wave)
            waveLayers.append(wave)
            waveShapes.append(SiriWave.random(power: 0))
            waveTargets.append(SiriWave.random(power: 0))
        }


        checkDisc.fillColor = NSColor.systemGreen.cgColor
        checkDisc.isHidden = true
        content.addSublayer(checkDisc)
        checkStroke.strokeColor = NSColor.white.cgColor
        checkStroke.fillColor = NSColor.clear.cgColor
        checkStroke.lineWidth = 2.4
        checkStroke.lineCap = .round
        checkStroke.lineJoin = .round
        checkStroke.isHidden = true
        content.addSublayer(checkStroke)

        symbol.contentsGravity = .resizeAspect
        symbol.contentsScale = 2
        content.addSublayer(symbol)

        label.font = Text.font
        label.fontSize = Text.font.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .left
        label.truncationMode = .end
        label.contentsScale = 2

        sublabel.font = Text.subFont
        sublabel.fontSize = Text.subFont.pointSize
        sublabel.foregroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        sublabel.alignmentMode = .left
        sublabel.truncationMode = .end
        sublabel.contentsScale = 2
        content.addSublayer(sublabel)

        halo.backgroundColor = WavePalette.instruct[0].withAlphaComponent(0.35).cgColor
        halo.opacity = 0
        content.insertSublayer(halo, at: 0)
        content.addSublayer(label)

        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [
            NSColor.white.withAlphaComponent(0.55).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.55).cgColor,
        ]
        shimmer.locations = [0.35, 0.5, 0.65]

        timer.string = "0:00"
        timer.font = Text.clockFont
        timer.fontSize = Text.clockFont.pointSize
        timer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        timer.alignmentMode = .left
        timer.truncationMode = .none
        timer.contentsScale = 2
        content.addSublayer(timer)

        // Above the contents so the hairline is never painted over.
        pill.addSublayer(rim)

        miniArt.cornerRadius = 5
        miniArt.masksToBounds = true
        miniArt.contentsGravity = .resizeAspectFill
        miniArt.opacity = 0
        miniArt.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        pill.addSublayer(miniArt)
        for bar in miniBars {
            bar.fillColor = barsAccent
            bar.opacity = 0
            pill.addSublayer(bar)
        }

        hudIcon.contentsGravity = .resizeAspect
        hudLabel.string = "Sound"
        hudLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        hudLabel.fontSize = 13
        hudLabel.foregroundColor = NSColor.white.cgColor
        hudValue.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        hudValue.fontSize = 12
        hudValue.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        hudValue.alignmentMode = .right
        hudTrack.fillColor = NSColor.white.withAlphaComponent(0.22).cgColor
        hudFill.fillColor = Self.hudGreen.cgColor
        for l in [hudIcon, hudLabel, hudTrack, hudFill, hudValue] as [CALayer] {
            l.opacity = 0
            pill.addSublayer(l)
        }
    }

    /// Volume changed: widen into the Sound pill (or just move the meter if
    /// it is already up).
    func showHUD(level: Float, icon: String) {
        hudLevel = level
        hudIconName = icon
        let was = hudActive
        hudActive = true
        if was { layoutHUD(state) } else { layoutPill(state, animated: true) }
    }

    func hideHUD() {
        guard hudActive else { return }
        hudActive = false
        layoutPill(state, animated: true)
    }

    private func layoutHUD(_ s: IslandState) {
        let show = hudActive && (s == .closed || s == .peek) && pillVisible(s)
        let f = pillFrame(s)
        let h = housing(s) + chinHeight(s)
        let midY = (h - topInset(s)) / 2
        let alpha: Float = show ? 1 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        // Left cluster: icon · Sound.
        let iconSize: CGFloat = 16
        var x = (-f.width / 2 + 14 + flare(s)).rounded()
        hudIcon.contents = symbolImage(hudIconName, size: 13, color: .white)
        hudIcon.frame = CGRect(x: x, y: (midY - iconSize / 2).rounded(), width: iconSize, height: iconSize)
        x += iconSize + 7
        let labelH = ceil(NSFont.systemFont(ofSize: 13, weight: .semibold).ascender - NSFont.systemFont(ofSize: 13).descender)
        hudLabel.frame = CGRect(x: x, y: (midY - labelH / 2).rounded() - 1, width: 60, height: labelH)
        // Right cluster: meter · value.
        let valueW: CGFloat = 26
        let meterW: CGFloat = 46
        let right = (f.width / 2 - 14 - flare(s)).rounded()
        hudValue.frame = CGRect(x: right - valueW, y: (midY - 8).rounded(), width: valueW, height: 15)
        hudValue.string = "\(Int((hudLevel * 100).rounded()))"
        let track = CGRect(x: right - valueW - 9 - meterW, y: (midY - 2.5).rounded(), width: meterW, height: 5)
        hudTrack.frame = track
        hudTrack.path = CGPath(roundedRect: CGRect(origin: .zero, size: track.size), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        let fillW = max(hudLevel > 0 ? 5 : 0, meterW * CGFloat(hudLevel))
        hudFill.frame = CGRect(x: track.minX, y: track.minY, width: fillW, height: 5)
        hudFill.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: fillW, height: 5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        for l in [hudIcon, hudLabel, hudTrack, hudFill, hudValue] as [CALayer] { l.opacity = alpha }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { nil }

    /// Rust/SwiftUI tell us what is playing; the resting pill grows around
    /// the housing to show it, and shrinks back when it stops.
    func setMedia(available: Bool, playing: Bool, artwork: NSImage?, accent: NSColor) {
        let wasPill = mediaPill(state)
        mediaAvailable = available
        mediaPlaying = playing
        barsAccent = accent.cgColor
        if let artwork, let cg = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            miniArt.contents = cg
        } else if !available {
            miniArt.contents = nil
        }
        for bar in miniBars { bar.fillColor = barsAccent }
        if mediaPill(state) != wasPill {
            layoutPill(state, animated: true)
        } else {
            layoutMini(state)
        }
    }

    /// Place and animate the mini artwork + bars for a state.
    private func layoutMini(_ s: IslandState) {
        let show = mediaPill(s)
        let f = pillFrame(s)
        // Pill-local coordinates: origin at bottom-centre of the pill layer's
        // bounds (islandBounds), y up.
        let h = housing(s) + chinHeight(s)
        // In the banner the artwork/bars hold the top band (beside the
        // housing), not the banner's centre.
        let band = (s == .open && mode.isAnnounce) ? max(housing(s), 28) : h - topInset(s)
        let midY = h - topInset(s) - band / 2
        // As tall as the pill allows (the iPhone island fills its ends),
        // capped at miniSize so it never dominates a big virtual pill.
        let art = max(12, min(Self.miniSize, h - topInset(s) - 8))
        let leftX = (-f.width / 2 + Self.miniPad + flare(s)).rounded()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        miniArt.frame = CGRect(x: leftX, y: (midY - art / 2).rounded(), width: art, height: art)
        miniArt.opacity = show ? 1 : 0
        let barW: CGFloat = 2.5, gap: CGFloat = 2.5, maxH: CGFloat = 12
        let barsW = barW * 4 + gap * 3
        let rightX = (f.width / 2 - Self.miniPad - flare(s) - barsW).rounded()
        let dance = show && mediaPlaying
        for (i, bar) in miniBars.enumerated() {
            let x = rightX + CGFloat(i) * (barW + gap)
            // Fixed geometry (a full-height bar), pixel-aligned; only the
            // scale changes, so nothing re-rasterises or shifts.
            if bar.path == nil {
                bar.bounds = CGRect(x: 0, y: 0, width: barW, height: maxH)
                bar.path = CGPath(roundedRect: bar.bounds, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
            }
            bar.position = CGPoint(x: x + barW / 2, y: midY.rounded())
            bar.opacity = show ? 1 : 0
            let rest: CGFloat = 3 / maxH
            if dance {
                if !barsDancing {
                    let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
                    let peaks: [[CGFloat]] = [[0.35, 0.9, 0.5, 0.75], [1.0, 0.45, 0.8, 0.6], [0.5, 0.95, 0.4, 0.85], [0.7, 0.4, 0.9, 0.55]]
                    a.values = peaks[i] + [peaks[i][0]]
                    a.duration = 0.9 + Double(i) * 0.13
                    a.repeatCount = .infinity
                    a.calculationMode = .cubic
                    a.beginTime = CACurrentMediaTime() + Double(i) * 0.05
                    a.fillMode = .backwards
                    bar.transform = CATransform3DMakeScale(1, peaks[i][0], 1)
                    bar.add(a, forKey: "dance")
                }
            } else {
                bar.removeAnimation(forKey: "dance")
                bar.transform = CATransform3DMakeScale(1, rest, 1)
            }
        }
        barsDancing = dance
        CATransaction.commit()
    }

    func configure(cutoutWidth: CGFloat, safeAreaTop: CGFloat, synthetic: Bool, scale: CGFloat) {
        self.cutoutWidth = cutoutWidth
        self.safeAreaTop = safeAreaTop
        self.synthetic = synthetic
        // Text and glyphs rasterise for the screen the island is on — a 1×
        // external display drawn at 2× (or the reverse) looks soft.
        contentScale = scale
        for l in [symbol, label, sublabel, timer, hudLabel, hudValue, hudIcon] as [CALayer] { l.contentsScale = scale }
        layoutPill(.closed, animated: false)
    }

    /// On a screen without a housing the island rests as a small pill at the
    /// top-centre (over the empty middle of the menu bar) and grows from it;
    /// open and expanded use the full MacBook-sized width so the hints fit.
    /// Alcove's resting pill is about 2.6× as wide as it is tall.
    private var virtualPillWidth: CGFloat { max(56, (safeAreaTop - topInset(.closed)) * 2.6 - Island.overhang(.closed) * 2) }
    private func baseWidth(_ s: IslandState) -> CGFloat {
        synthetic && (s == .closed || s == .peek) ? virtualPillWidth : cutoutWidth
    }
    private func pillVisible(_ s: IslandState) -> Bool { !(yielding && s == .closed) }

    /// The concave fillets sell the island as part of a housing. With no
    /// housing they are chrome pretending to be hardware, so a virtual island
    /// is a plain rounded-bottom shape. Zero keeps the path's segment count,
    /// so the spring still interpolates between states.
    private func flare(_ s: IslandState) -> CGFloat { synthetic ? 0 : Island.flare(s) }

    /// Without flares the bottom corners carry the whole shape, so a virtual
    /// island rounds them more once it has grown (Alcove's proportions).
    /// A virtual island never touches the screen edge: every state is a
    /// floating rounded box (all four corners round), a few points below the
    /// top, like Alcove's. Only its size and radius change.
    private func topInset(_ s: IslandState) -> CGFloat { synthetic ? 3 : 0 }
    private func topRadius(_ s: IslandState) -> CGFloat { synthetic ? cornerRadius(s) : 0 }
    /// The band above the chin. Real: the housing. Virtual at rest: the
    /// pill's whole height; open: just top padding, so content sits centred
    /// in the box instead of below a housing that isn't there.
    private func housing(_ s: IslandState) -> CGFloat {
        synthetic && (s == .open || s == .expanded) ? 12 : safeAreaTop
    }
    private func cornerRadius(_ s: IslandState) -> CGFloat {
        guard synthetic else {
            if hudActive, s == .closed || s == .peek { return (housing(s) + chinHeight(s)) / 2 }
            if s == .open, mode.isAnnounce { return 26 }
            // The media pill wraps the housing like the iPhone island: full
            // round ends.
            if mediaPill(s) { return (housing(s) + chinHeight(s)) / 2 }
            return Island.cornerRadius(s)
        }
        return switch s {
        // Resting states are stadiums: radius = half the visible height.
        case .closed, .peek: (housing(s) + chinHeight(s) - topInset(s)) / 2
        case .open: 30
        case .expanded: 36
        }
    }

    /// AppKit's y axis points up, so the pill hangs from the top of the view.
    private func pillFrame(_ s: IslandState) -> CGRect {
        // The frame includes the flares; the body is inset by flare per side,
        // so the visible body still covers the cutout (plus slop) when closed.
        let over = s == .expanded ? expandedOverhang : Island.overhang(s)
        let hud = hudActive && (s == .closed || s == .peek) ? Self.hudExtra : 0
        let width = baseWidth(s) + (over + flare(s) + max(hud, mediaPill(s) ? mediaExtra : 0)) * 2
        let height = housing(s) + chinHeight(s)
        return CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    private func path(for size: CGSize, _ s: IslandState, closed: Bool = true) -> CGPath {
        islandPath(size: size, cornerRadius: cornerRadius(s), flare: flare(s), topRadius: topRadius(s), topInset: topInset(s), closed: closed)
    }

    /// The pill's current footprint plus hover slop, in view coordinates.
    var hoverRect: CGRect {
        pillFrame(state).insetBy(dx: -Island.hoverSlop(state), dy: -Island.hoverSlop(state))
    }

    /// Where the top-centre of the pill sits in the view. Constant.
    private var pillTop: CGPoint { CGPoint(x: bounds.width / 2, y: bounds.height) }

    /// The chin rect of a state, in view coordinates (y-up).
    private func chinRect(_ s: IslandState) -> CGRect {
        let f = pillFrame(s)
        let inset = flare(s) + 10
        return CGRect(
            x: f.minX + inset,
            y: f.minY + 8,
            width: f.width - inset * 2,
            height: chinHeight(s) - 12
        )
    }

    private func layoutNotesHost(for s: IslandState, animated: Bool) {
        guard let host = notesHost else { return }
        host.wantsLayer = true
        if s == .expanded {
            host.frame = chinRect(.expanded)
            host.isHidden = false
            guard let layer = host.layer else { host.alphaValue = 1; return }
            // Scale from the top edge, where the island grows from.
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.position = CGPoint(x: host.frame.midX, y: host.frame.maxY)
            if animated {
                // The card is revealed by the shape opening: it starts a beat
                // later, slightly small and soft, and springs to place while
                // the island is still settling — never a flat fade.
                layer.opacity = 0
                layer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.state == .expanded else { return }
                    let scale = springAnimation(keyPath: "transform", duration: 0.5, bounce: 0.2)
                    scale.fromValue = layer.presentation()?.transform ?? layer.transform
                    scale.toValue = CATransform3DIdentity
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = layer.presentation()?.opacity ?? 0
                    fade.toValue = 1
                    fade.duration = 0.28
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.transform = CATransform3DIdentity
                    layer.opacity = 1
                    layer.add(scale, forKey: "transform")
                    layer.add(fade, forKey: "opacity")
                }
            } else {
                layer.transform = CATransform3DIdentity
                layer.opacity = 1
            }
        } else if !host.isHidden {
            guard let layer = host.layer else { host.isHidden = true; return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = layer.presentation()?.transform ?? layer.transform
            shrink.toValue = CATransform3DMakeScale(0.94, 0.94, 1)
            shrink.duration = 0.16
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.opacity = 0
            layer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
            layer.add(fade, forKey: "opacity")
            layer.add(shrink, forKey: "transform")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
                guard let self, self.state != .expanded else { return }
                host.isHidden = true
            }
        }
    }

    func layoutPill(_ s: IslandState, animated: Bool) {
        layoutNotesHost(for: s, animated: animated)
        let growing = chinHeight(s) > chinHeight(state)
        let leavingOpen = state == .open && s != .open
        // Peek in/out is a small move between the resting states.
        let peeking = (s == .peek && state == .closed) || (s == .closed && state == .peek)
        state = s
        let target = pillFrame(s)
        let targetBounds = islandBounds(target.size)
        let targetPath = path(for: target.size, s)
        let shadowOpacity = Island.shadowOpacity(s)

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for l in [pill, shadowLayer] {
                l.position = pillTop
                l.bounds = targetBounds
            }
            pill.path = targetPath
            for shape in [clip, rim] {
                shape.position = .zero
                shape.bounds = targetBounds
            }
            clip.path = targetPath
            rim.path = path(for: target.size, s, closed: false)
            shadowLayer.shadowPath = targetPath
            shadowLayer.shadowOpacity = shadowOpacity
            pill.opacity = pillVisible(s) ? 1 : 0
            shadowLayer.opacity = pill.opacity
            layoutContents(s)
            CATransaction.commit()
            return
        }

        let toCard = s == .expanded
        var duration = toCard ? Island.expandDuration : growing ? Island.growDuration : Island.shrinkDuration
        var bounce = toCard ? Island.expandBounce : growing ? Island.growBounce : Island.shrinkBounce
        if peeking {
            duration = Island.peekDuration
            bounce = growing ? Island.peekBounce : 0.08
        }

        // One spring for bounds, one for the outline; nothing has a position
        // to animate. Bounds and path must share the identical spring, or the
        // flares visibly detach from the corners mid-animation.
        let boundsSpring = springAnimation(keyPath: "bounds", duration: duration, bounce: bounce)
        boundsSpring.fromValue = NSValue(rect: pill.bounds)
        boundsSpring.toValue = NSValue(rect: targetBounds)

        let pathSpring = springAnimation(keyPath: "path", duration: duration, bounce: bounce)
        pathSpring.fromValue = pill.path
        pathSpring.toValue = targetPath

        // The rim strokes the outline minus the top edge; same spring, its
        // own (unclosed) path.
        let rimPath = path(for: target.size, s, closed: false)
        let rimSpring = springAnimation(keyPath: "path", duration: duration, bounce: bounce)
        rimSpring.fromValue = rim.path
        rimSpring.toValue = rimPath

        let shadowSpring = springAnimation(keyPath: "shadowPath", duration: duration, bounce: bounce)
        shadowSpring.fromValue = shadowLayer.shadowPath
        shadowSpring.toValue = targetPath

        // Leaving the open state: content melts first, then the container
        // follows. Shrinking everything at once is what reads as "sudden" —
        // Apple's islands always retire the content a beat before the shape.
        let contentLead: CFTimeInterval = leavingOpen ? Island.contentOutLead : 0
        for anim in [boundsSpring, pathSpring, shadowSpring, rimSpring] {
            anim.beginTime = CACurrentMediaTime() + contentLead
            anim.fillMode = .backwards
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        pill.bounds = targetBounds
        pill.path = targetPath
        pill.add(boundsSpring, forKey: "bounds")
        pill.add(pathSpring, forKey: "path")
        for shape in [clip, rim] {
            shape.bounds = targetBounds
            shape.add(boundsSpring, forKey: "bounds")
        }
        clip.path = targetPath
        clip.add(pathSpring, forKey: "path")
        rim.path = rimPath
        rim.add(rimSpring, forKey: "path")
        // The shadow is a sibling layer (the pill would clip its own shadow).
        shadowLayer.bounds = targetBounds
        shadowLayer.shadowPath = targetPath
        shadowLayer.shadowOpacity = shadowOpacity
        shadowLayer.add(boundsSpring, forKey: "bounds")
        shadowLayer.add(shadowSpring, forKey: "shadowPath")
        // Virtual island: fade in ahead of the growth so it never pops, and
        // fade out with the shrink so it dissolves into the edge.
        let visible: Float = pillVisible(s) ? 1 : 0
        if pill.opacity != visible {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = pill.presentation()?.opacity ?? pill.opacity
            fade.toValue = visible
            fade.duration = visible == 1 ? 0.18 : duration * 0.6
            fade.timingFunction = CAMediaTimingFunction(name: visible == 1 ? .easeOut : .easeIn)
            for l in [pill, shadowLayer] as [CALayer] {
                l.opacity = visible
                l.add(fade, forKey: "opacity")
            }
        }
        layoutContents(s)
        CATransaction.commit()
    }

    /// Content lives in the chin, strictly below the housing — which, in this
    /// bottom-up coordinate space, is the LOWER part of the pill rect. The
    /// housing occupies the top `safeAreaTop` points.
    private func layoutContents(_ s: IslandState) {
        let open = s == .open
        layoutMini(s)
        layoutHUD(s)

        // The key line separates black island from black housing; a virtual
        // island has no housing to separate from, and reads as an outline.
        rim.opacity = (s == .closed || synthetic) ? 0 : 1

        // Content always keeps the open chin's geometry (top edge at the open
        // chin height, x = 0 the centre line); opacity/scale/blur do the
        // hiding and the mask clips it when the pill is shorter.
        let chinSize = CGSize(width: pillFrame(.open).width, height: Island.chinHeight(.open))
        content.bounds = CGRect(origin: .zero, size: chinSize)
        content.position = CGPoint(x: 0, y: Island.chinHeight(.open))

        // Content in: rides the container's spring. Content out: quick and
        // eased, ahead of the container (see layoutPill).
        let animating = CATransaction.animationDuration() > 0
        if open {
            // Fade + unfold on their own eased curve, delayed so the chin has
            // begun to open before anything appears in it. Springing the
            // opacity would make it flicker on the overshoot.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = content.presentation()?.opacity ?? content.opacity
            fade.toValue = 1
            let unfold = CABasicAnimation(keyPath: "transform")
            unfold.fromValue = content.presentation()?.transform ?? content.transform
            unfold.toValue = CATransform3DIdentity
            for a in [fade, unfold] {
                a.duration = Island.contentInDuration
                a.beginTime = CACurrentMediaTime() + (animating ? Island.contentInDelay : 0)
                a.fillMode = .backwards
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.opacity = 1
            content.transform = CATransform3DIdentity
            content.setValue(0, forKeyPath: "filters.blur.inputRadius")
            if animating {
                let unblur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
                unblur.fromValue = Island.contentOutBlur
                unblur.toValue = 0
                unblur.duration = fade.duration
                unblur.beginTime = fade.beginTime
                unblur.fillMode = .backwards
                unblur.timingFunction = fade.timingFunction
                content.add(fade, forKey: "opacity")
                content.add(unfold, forKey: "transform")
                content.add(unblur, forKey: "blur")
            }
            CATransaction.commit()
        } else {
            let out = animating ? Island.contentOutDuration : 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(out)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1))
            // Content is drawn up into the housing as it goes: it shrinks
            // about the housing edge (its anchor), blurs and fades — the iOS
            // island's exit, not a fade in place.
            content.opacity = 0
            content.transform = CATransform3DMakeScale(0.7, 0.7, 1)
            content.setValue(Island.contentOutBlur, forKeyPath: "filters.blur.inputRadius")
            CATransaction.commit()
            wavePowerTarget = 0
        }

        layoutCluster(in: chinSize)
    }

    /// One centred cluster per mode: dictate = wave (+ clock after 8 s);
    /// instruct = wave · hint; armed/working = ✦ · text; done = ✓ · Done.
    private func layoutCluster(in chinSize: CGSize) {
        let gap = Self.clusterGap
        let midY = chinSize.height / 2
        let recording = mode.isRecording

        // Tint everything that carries the mode colour.
        let tint: NSColor
        switch mode {
        case .dictate: tint = Tint.dictate
        case .instruct: tint = Tint.instruct
        case .armed: tint = Tint.instruct
        case .working: tint = Tint.instruct
        case .done(let ok, _): tint = ok ? Tint.ok : Tint.fail
        case .notes: tint = WavePalette.dictate[1]
        case .announce: tint = NSColor.white
        }
        let palette = mode == .instruct ? WavePalette.instruct : WavePalette.dictate
        for (i, wave) in waveLayers.enumerated() { wave.fillColor = palette[i].cgColor }
        // The clock reads in white beside a coloured wave; the record glyph
        // keeps its red — the one universally understood "recording" cue.
        timer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor

        // Which members are present.
        // Recording modes are the wave and the clock, nothing else: the wave
        // is the recording indicator. Glyphs belong to working/done.
        let isCheck = mode.isDone && mode.isSuccess
        symbol.isHidden = recording || isCheck
        checkDisc.isHidden = !isCheck
        checkStroke.isHidden = !isCheck
        for wave in waveLayers { wave.isHidden = !recording; wave.opacity = 1 }
        timer.isHidden = !recording
        // Starts invisible; updateTimer fades it in after Text.clockAfter.
        timer.opacity = 0
        symbol.opacity = 1
        label.isHidden = mode == .dictate

        // Symbol image + label text for the mode.
        let symbolName: String
        var text = ""
        var sub = ""
        switch mode {
        case .dictate: symbolName = ""
        case .instruct: symbolName = "sparkles"; text = "Describe the change"; sub = "tap or release to apply"
        case .armed: symbolName = "sparkles"; text = "Refine"; sub = "double-tap to describe"
        case .working(let s, let sym): symbolName = sym; text = s
        case .done(let ok, let label): symbolName = ok ? "" : "xmark.circle.fill"; text = label
        case .notes: symbolName = ""
        case .announce(let t, let a):
            symbolName = "music.note"
            text = a.isEmpty ? t : "\(t) · \(a)"
        }
        let announcing = mode.isAnnounce
        if !symbolName.isEmpty {
            let size = announcing ? 12 : Glyph.symbolSize
            let color = announcing ? NSColor.white.withAlphaComponent(0.6) : tint
            symbol.contents = symbolImage(symbolName, size: size, color: color)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = text
        sublabel.string = sub
        // The refine hints use the compact two-line face; everything else the
        // single 15pt line.
        let twoLine = !sub.isEmpty
        let singleFont = announcing ? Text.titleFont : Text.font
        label.font = twoLine ? Text.titleFont : singleFont
        label.fontSize = (twoLine ? Text.titleFont : singleFont).pointSize
        // The artist half of an announce goes quiet, like Alcove's.
        if case .announce(let t, let a) = mode, !a.isEmpty {
            let at = NSMutableAttributedString(
                string: t,
                attributes: [.font: Text.titleFont, .foregroundColor: NSColor.white]
            )
            at.append(NSAttributedString(
                string: "  ·  \(a)",
                attributes: [.font: Text.titleFont, .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
            ))
            label.string = at
        }
        sublabel.isHidden = !twoLine
        CATransaction.commit()

        // Measure the cluster: recording = wave · clock; otherwise glyph · label.
        let glyphWidth = announcing ? 14 : Glyph.symbolSize
        let titleFont = twoLine ? Text.titleFont : singleFont
        let titleWidth = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: titleFont]).width) + 2
        let subWidth = sub.isEmpty ? 0 : ceil((sub as NSString).size(withAttributes: [.font: Text.subFont]).width) + 2
        // Never wider than the chin allows; CATextLayer truncates with an ellipsis.
        let maxLabel = chinSize.width - 2 * (Island.flare(.open) + 12) - glyphWidth - gap
        let labelWidth = min(max(titleWidth, subWidth), maxLabel)
        let instruct = mode == .instruct
        let waveWidth = instruct ? Wave.instructWidth : Wave.totalWidth
        let clusterWidth = instruct ? waveWidth + gap + labelWidth
            : recording ? waveWidth : glyphWidth + gap + labelWidth
        var x = (chinSize.width - clusterWidth) / 2

        if !recording {
            let glyphRect = CGRect(x: x, y: midY - glyphWidth / 2, width: glyphWidth, height: glyphWidth)
            symbol.frame = glyphRect
            if isCheck {
                layoutCheck(in: glyphRect)
            }
            x += glyphWidth + gap
        }

        if recording {
            waveRect = CGRect(x: x, y: midY - Wave.maxHeight / 2, width: waveWidth, height: Wave.maxHeight)
            for wave in waveLayers { wave.frame = waveRect }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            redrawWaves()
            CATransaction.commit()
            // The clock sits at the right margin, off the wave, so its arrival
            // moves nothing.
            let clockHeight = ceil(Text.clockFont.ascender - Text.clockFont.descender)
            timer.frame = CGRect(
                x: chinSize.width - Island.flare(.open) - 12 - Text.clockWidth,
                y: midY - clockHeight / 2 - 1,
                width: Text.clockWidth,
                height: clockHeight
            )
            if instruct {
                x += waveWidth + gap
                placeText(x: x, midY: midY, width: labelWidth, twoLine: twoLine)
            }
        } else {
            placeText(x: x, midY: midY, width: labelWidth, twoLine: twoLine)
        }

        // Armed: the sparkle pops in (spring, slight overshoot) with a soft
        // halo that blooms once behind it — "I heard you; hold to say a
        // change". Instruct: the sparkle has already morphed into the wave
        // (see setMode); nothing extra here.
        if mode == .armed {
            let d = Glyph.symbolSize * 2.6
            halo.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            halo.cornerRadius = d / 2
            halo.position = CGPoint(x: symbol.frame.midX, y: symbol.frame.midY)
            if symbol.animation(forKey: "pop") == nil {
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.4
                pop.toValue = 1
                pop.mass = 1; pop.stiffness = 300; pop.damping = 16
                pop.duration = pop.settlingDuration
                symbol.add(pop, forKey: "pop")

                let bloomScale = CABasicAnimation(keyPath: "transform.scale")
                bloomScale.fromValue = 0.3
                bloomScale.toValue = 1.15
                let bloomFade = CAKeyframeAnimation(keyPath: "opacity")
                bloomFade.values = [0, 0.9, 0]
                bloomFade.keyTimes = [0, 0.3, 1]
                let bloom = CAAnimationGroup()
                bloom.animations = [bloomScale, bloomFade]
                bloom.duration = 0.6
                bloom.timingFunction = CAMediaTimingFunction(name: .easeOut)
                halo.add(bloom, forKey: "bloom")
            }
        }

        // Working: the sparkle breathes and light sweeps through the label, so
        // a long call still reads as alive.
        if case .working = mode {
            // The gradient is three label-widths wide and slides one width per
            // cycle, so the bright band crosses the text left to right.
            let w = max(labelWidth, 1)
            shimmer.frame = CGRect(x: -w, y: 0, width: w * 3, height: label.bounds.height)
            label.mask = shimmer
            if shimmer.animation(forKey: "sweep") == nil {
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = shimmer.position.x - w
                sweep.toValue = shimmer.position.x + w
                sweep.duration = 1.4
                sweep.repeatCount = .infinity
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shimmer.add(sweep, forKey: "sweep")
            }
            if symbol.animation(forKey: "breathe") == nil {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1
                breathe.toValue = 0.35
                breathe.duration = 0.8
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                symbol.add(breathe, forKey: "breathe")
            }
        } else {
            symbol.removeAnimation(forKey: "breathe")
            shimmer.removeAnimation(forKey: "sweep")
            label.mask = nil
        }
    }

    /// Title (and sub, if any) at `x`, vertically centred as a block.
    private func placeText(x: CGFloat, midY: CGFloat, width: CGFloat, twoLine: Bool) {
        if twoLine {
            let th = ceil(Text.titleFont.ascender - Text.titleFont.descender)
            let sh = ceil(Text.subFont.ascender - Text.subFont.descender)
            let gap: CGFloat = 1
            let block = th + gap + sh
            // y-up: title on top.
            label.frame = CGRect(x: x, y: midY - block / 2 + sh + gap, width: width, height: th)
            sublabel.frame = CGRect(x: x, y: midY - block / 2, width: width, height: sh)
        } else {
            let th = ceil(Text.font.ascender - Text.font.descender)
            label.frame = CGRect(x: x, y: midY - th / 2 - 1, width: width, height: th)
        }
    }

    /// Place the completion mark in `rect` and play it: disc pops (scale
    /// 0.5 → 1 with a small overshoot), then the check strokes on over
    /// 0.28s. Re-layout while showing does not replay.
    private func layoutCheck(in rect: CGRect) {
        let d = rect.width
        checkDisc.frame = rect
        checkDisc.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
        checkStroke.frame = rect
        // Check geometry in the disc's local space (y-up): short stroke down
        // to the elbow, long stroke up to the tip.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: d * 0.28, y: d * 0.52))
        p.addLine(to: CGPoint(x: d * 0.44, y: d * 0.35))
        p.addLine(to: CGPoint(x: d * 0.73, y: d * 0.66))
        checkStroke.path = p

        guard checkDisc.animation(forKey: "pop") == nil else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.5
        pop.toValue = 1
        pop.mass = 1; pop.stiffness = 320; pop.damping = 18
        pop.duration = pop.settlingDuration
        checkDisc.add(pop, forKey: "pop")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.28
        draw.beginTime = CACurrentMediaTime() + 0.08
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        checkStroke.strokeEnd = 1
        checkStroke.add(draw, forKey: "draw")
    }

    /// A tinted SF Symbol as a CGImage, rasterised for the screen's scale.
    /// Without the CTM hint `cgImage(forProposedRect:)` renders at 1× and
    /// the glyph is soft on Retina.
    private func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> CGImage? {
        guard #available(macOS 12.0, *) else { return nil }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = base?.withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        let hints: [NSImageRep.HintKey: Any] = [
            .ctm: NSAffineTransform(transform: AffineTransform(scale: contentScale)),
        ]
        return image.cgImage(forProposedRect: &rect, context: nil, hints: hints)
    }

    /// How long the wave settles on release before the next mode is revealed.
    private static let releaseSettle: CFTimeInterval = 0.34
    private var modeGeneration = 0
    /// The armed hint has to be readable: the gesture resolves at the tap
    /// window, but the island keeps "Refine / press again to describe a
    /// change" on screen for at least this long before moving on. A second
    /// press (→ instruct) is never delayed.
    private static let armedMinDwell: TimeInterval = 1.6
    private var armedAt: TimeInterval = 0
    private var deferredMode: DispatchWorkItem?

    /// How much longer the armed hint must stay before another mode may
    /// replace it (0 when not armed).
    func remainingArmedDwell() -> TimeInterval {
        guard mode == .armed else { return 0 }
        return max(0, Self.armedMinDwell - (CACurrentMediaTime() - armedAt))
    }

    func setMode(_ m: IslandMode) {
        guard m != mode else { return }
        // Armed → recording always means the hold began; the pipeline's
        // generic "recording" (dictate) arrives a beat before "instruct" and
        // would flash the plain wave. Skip it; instruct follows at once.
        if mode == .armed, m == .dictate { return }
        let armedToInstruct = mode == .armed && m == .instruct
        deferredMode?.cancel()
        if mode == .armed, !armedToInstruct {
            let shown = CACurrentMediaTime() - armedAt
            if shown < Self.armedMinDwell {
                let work = DispatchWorkItem { [weak self] in self?.setMode(m) }
                deferredMode = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (Self.armedMinDwell - shown), execute: work)
                return
            }
        }
        if m == .armed { armedAt = CACurrentMediaTime() }
        let wasRecording = mode.isRecording
        mode = m
        modeGeneration += 1
        let generation = modeGeneration
        if m.isRecording {
            if !wasRecording { startRecording() }
        } else {
            stopRecording()
        }

        let reveal = { [weak self] in
            guard let self, self.modeGeneration == generation else { return }
            let chinSize = CGSize(width: self.pillFrame(.open).width, height: Island.chinHeight(.open))
            if self.state == .open {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.22
                self.content.add(fade, forKey: "mode")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layoutCluster(in: chinSize)
            CATransaction.commit()
            if armedToInstruct {
                // The sparkle becomes the wave: the wave grows out of where
                // the sparkle was, on a spring, so the commit reads as one
                // thing turning into another rather than a swap.
                for wave in self.waveLayers {
                    let grow = CASpringAnimation(keyPath: "transform.scale")
                    grow.fromValue = 0.2
                    grow.toValue = 1
                    grow.mass = 1; grow.stiffness = 260; grow.damping = 20
                    grow.duration = grow.settlingDuration
                    wave.add(grow, forKey: "grow")
                }
            }
        }

        // Recording → anything else while open: let the wave settle first.
        // Bars fall to the midline, timer and glyph fade; then reveal.
        guard wasRecording, !m.isRecording, state == .open else {
            reveal()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.releaseSettle)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        // The wave drains to a still line; the tick keeps
        // running through the settle so the drain is drawn, not cut.
        wavePowerTarget = 0
        for wave in waveLayers { wave.opacity = 0.35 }
        timer.opacity = 0
        symbol.opacity = 0
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseSettle * 0.85, execute: reveal)
    }

    /// Mic level, 0...1, at ~24 Hz. Sets the wave's power target and the
    /// the 30 Hz tick eases toward it.
    /// Song changed while the banner is up: flip the caption like the
    /// iPhone island — the old line rolls away on a top hinge, the new one
    /// rolls in and settles on a spring.
    func announceSwap(_ m: IslandMode) {
        guard state == .open, mode.isAnnounce else {
            setMode(m)
            return
        }
        var persp = CATransform3DIdentity
        persp.m34 = -1 / 400
        let out = CABasicAnimation(keyPath: "transform")
        out.fromValue = CATransform3DIdentity
        out.toValue = CATransform3DRotate(persp, .pi / 2, 1, 0, 0)
        out.duration = 0.15
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.setMode(m)
            let back = springAnimation(keyPath: "transform", duration: 0.5, bounce: 0.25)
            back.fromValue = CATransform3DRotate(persp, -.pi / 2, 1, 0, 0)
            back.toValue = CATransform3DIdentity
            self.content.transform = CATransform3DIdentity
            self.content.add(back, forKey: "flip")
        }
        content.transform = CATransform3DRotate(persp, .pi / 2, 1, 0, 0)
        content.add(out, forKey: "flip")
        CATransaction.commit()
    }

    func setLevel(_ level: CGFloat) {
        // Levels can trail the stop by a few callbacks; once the mode has left
        // recording they must not fight the wave's settle.
        guard state == .open, mode.isRecording else { return }
        // Perceptual: raw peaks for speech sit around 0.05-0.3, which on a
        // linear scale barely moves the wave. sqrt lifts the quiet range.
        let l = sqrt(max(0, min(level, 1)))
        wavePowerTarget = Wave.idlePower + (1 - Wave.idlePower) * l
    }

    /// One frame of wave motion: ease power and each layer's composition
    /// toward their targets, re-roll targets on the interval, redraw.
    private func tickWaves() {
        let now = CACurrentMediaTime()
        // Attack fast (speech should show the same syllable, not the next),
        // release slower so the wave breathes down instead of collapsing.
        let k: CGFloat = wavePowerTarget > wavePower ? 0.55 : 0.10
        wavePower += (wavePowerTarget - wavePower) * k
        if now - lastReroll > Wave.rerollInterval {
            lastReroll = now
            for i in waveTargets.indices { waveTargets[i] = SiriWave.random(power: 1) }
        }
        for i in waveShapes.indices { waveShapes[i].ease(toward: waveTargets[i], by: 0.10) }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 60.0)
        redrawWaves()
        CATransaction.commit()
        // Stop ticking once drained and idle.
        if !mode.isRecording, wavePower < 0.005 {
            waveTick?.invalidate(); waveTick = nil
        }
    }

    private func redrawWaves() {
        guard waveRect.width > 0 else { return }
        let size = waveRect.size
        for (i, wave) in waveLayers.enumerated() {
            wave.path = waveShapes[i].path(in: size, power: wavePower, phaseShift: Double(i) * 0.9)
        }
    }

    private func startWaveTick() {
        waveTick?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickWaves()
        }
        // .common, or the wave freezes while a menu is open or a window drags.
        RunLoop.main.add(t, forMode: .common)
        waveTick = t
    }

    /// A fresh recording starts with a still wave and 0:00, not the tail of
    /// the last one.
    func startRecording() {
        wavePower = 0
        wavePowerTarget = Wave.idlePower
        startWaveTick()
        recordingStart = Date()
        updateTimer()
        timerTick?.invalidate()
        timerTick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
    }

    func stopRecording() {
        timerTick?.invalidate()
        timerTick = nil
        recordingStart = nil
        wavePowerTarget = 0
        // Keep ticking so the drain is drawn; tickWaves stops itself once still.
        if waveTick == nil { startWaveTick() }
    }

    private func updateTimer() {
        guard let start = recordingStart else { return }
        let seconds = Date().timeIntervalSince(start)
        let elapsed = Int(seconds)
        let text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        // Text changes must not cross-fade; a ticking clock should just tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timer.string = text
        CATransaction.commit()
        // Only plain dictation gets the clock; in describe-mode the right side
        // is the hint.
        if clockEnabled, seconds >= Text.clockAfter, timer.opacity == 0, mode == .dictate {
            timer.opacity = 1 // implicit fade
        }
    }
}

// MARK: - Siri wave

/// One sine component: amplitude, frequency, phase.
private struct SiriCurve {
    var a: Double, k: Double, t: Double
    static func random() -> SiriCurve {
        SiriCurve(a: .random(in: 0.2...1.0), k: .random(in: 0.6...0.9), t: .random(in: -1.0...4.0))
    }
    mutating func ease(toward o: SiriCurve, by f: Double) {
        a += (o.a - a) * f; k += (o.k - k) * f; t += (o.t - t) * f
    }
}

/// A composition of four curves. `path` renders it as a closed shape mirrored
/// about the midline, attenuated toward the ends so it tapers like the mark.
private struct SiriWave {
    var curves: [SiriCurve]
    static func random(power: Double) -> SiriWave {
        SiriWave(curves: (0..<4).map { _ in SiriCurve.random() })
    }
    mutating func ease(toward o: SiriWave, by f: Double) {
        for i in curves.indices { curves[i].ease(toward: o.curves[i], by: f) }
    }
    func path(in size: CGSize, power: CGFloat, phaseShift: Double) -> CGPath {
        let n = 48
        let w = Double(size.width), h = Double(size.height)
        let midY = h / 2
        let amp = Double(power) * midY * 0.95
        var top: [CGPoint] = []
        top.reserveCapacity(n + 1)
        for i in 0...n {
            let u = Double(i) / Double(n)          // 0...1
            let x = (u * 2 - 1) * 2                // -2...2 like the original
            let att = pow(4 / (4 + pow(x, 4)), 4)  // bell envelope
            var y = 0.0
            for c in curves { y += c.a * sin(c.k * x * .pi + c.t + phaseShift) }
            y = y / Double(curves.count) * att * amp
            top.append(CGPoint(x: u * w, y: midY + y))
        }
        let p = CGMutablePath()
        p.move(to: top[0])
        for pt in top.dropFirst() { p.addLine(to: pt) }
        for pt in top.reversed() { p.addLine(to: CGPoint(x: pt.x, y: 2 * midY - pt.y)) }
        p.closeSubpath()
        return p
    }
}

// MARK: - System volume (for the Sound HUD)

/// Watches the default output device's volume; the island shows a brief
/// Sound HUD when it changes (volume keys, menu-bar slider). Re-attaches
/// when the default output device itself changes.
private enum VolumeWatcher {
    private static var started = false
    private static var device: AudioObjectID = 0
    private static var onChange: ((Float, String) -> Void)?
    private static var volumeBlock: AudioObjectPropertyListenerBlock?
    private static var volAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var defAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func start(_ cb: @escaping (Float, String) -> Void) {
        guard !started else { return }
        started = true
        onChange = cb
        attach()
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defAddr, .main
        ) { _, _ in
            detach()
            attach()
        }
    }

    private static func defaultOutput() -> AudioObjectID? {
        var addr = defAddr
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let ok = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        ) == noErr && id != 0
        return ok ? id : nil
    }

    private static func attach() {
        guard let id = defaultOutput() else { return }
        device = id
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange?(current(), icon())
        }
        volumeBlock = block
        AudioObjectAddPropertyListenerBlock(device, &volAddr, .main, block)
    }

    private static func detach() {
        guard device != 0, let block = volumeBlock else { return }
        AudioObjectRemovePropertyListenerBlock(device, &volAddr, .main, block)
        volumeBlock = nil
        device = 0
    }

    static func current() -> Float {
        guard device != 0 else { return 0 }
        var addr = volAddr
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr else { return 0 }
        return v
    }

    /// Headphone-ish outputs get the headphones glyph, like Alcove.
    static func icon() -> String {
        guard device != 0 else { return "speaker.wave.2.fill" }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &t) == noErr,
           t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE {
            return "headphones"
        }
        return "speaker.wave.2.fill"
    }
}

// MARK: - Panel

/// Housing height and cutout width for a screen. Real on a notched display;
/// on any other screen the island is *virtual*: it hangs from the top edge
/// over the centre of the menu bar (which is empty there), sized like a
/// MacBook Pro housing, and is invisible at rest — there is no hardware to
/// fuse with, so at rest there is nothing to draw.
private struct ScreenMetrics {
    let safeAreaTop: CGFloat
    let cutoutWidth: CGFloat
    let synthetic: Bool
}

private func screenMetrics(of screen: NSScreen) -> ScreenMetrics {
    if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
        let auxWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        return ScreenMetrics(
            safeAreaTop: screen.safeAreaInsets.top,
            cutoutWidth: max(screen.frame.width - auxWidth * 2, 0),
            synthetic: false
        )
    }
    // Just shy of the menu bar's height (the resting pill floats 2pt below
    // the edge and stops a hair above the bar's bottom), or a housing-like
    // 24 when the bar is hidden.
    let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
    return ScreenMetrics(
        safeAreaTop: menuBar > 0 ? menuBar - 2 : 24,
        cutoutWidth: 180,
        synthetic: true
    )
}

/// Other apps that live in the notch. One notch: when one of these is
/// running Noi yields the resting state to it — draws nothing at rest,
/// ignores hover and click — and only appears, above it, while it has
/// something to say (dictating, refining, a result).
private let notchAppBundleIds: Set<String> = [
    "com.henrikruscon.Alcove",
    "theboringteam.boringnotch",
    "com.lo.NotchNook",
    "com.notchnook.NotchNook",
    "com.dynamiclake.DynamicLake",
    "com.notchmeister.Notchmeister",
    "com.mediaflow.MediaMate",
]

private func otherNotchAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { app in
        if let id = app.bundleIdentifier, notchAppBundleIds.contains(id) { return true }
        let name = app.localizedName?.lowercased() ?? ""
        return name == "alcove" || name.contains("boringnotch") || name.contains("boring.notch")
            || name.contains("notchnook") || name.contains("dynamiclake")
    }
}

/// The screen to use *right now*, from cheap signals only: the pointer,
/// else the notched display, else the first. Must stay non-blocking — it
/// runs on the main thread on every show().
private func quickScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return s }
    if let s = NSScreen.screens.first(where: { !screenMetrics(of: $0).synthetic }) { return s }
    return NSScreen.screens.first
}

/// The screen the user is working on: where the frontmost app's focused
/// window is (that is where dictation lands). The AX query can block on a
/// busy app, so it is only ever called off the main thread; callers show on
/// quickScreen() immediately and re-place if this disagrees.
private func workingScreen() -> NSScreen? {
    if let s = focusedWindowScreen() { return s }
    return quickScreen()
}

/// Screen containing the frontmost app's focused window, via Accessibility
/// (which dictation already needs). AX coordinates are top-left origin on the
/// primary screen; AppKit's are bottom-left.
private func focusedWindowScreen() -> NSScreen? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    // Cap how long an unresponsive app may hold us (default is seconds).
    AXUIElementSetMessagingTimeout(ax, 0.1)
    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
          let winRef else { return nil }
    let win = winRef as! AXUIElement
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posRef, let sizeRef else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
          let primary = NSScreen.screens.first else { return nil }
    let centre = CGPoint(
        x: pos.x + size.width / 2,
        y: primary.frame.maxY - (pos.y + size.height / 2)
    )
    return NSScreen.screens.first { $0.frame.contains(centre) }
}

private final class IslandController {
    static let shared = IslandController()

    private var panel: NSPanel?
    private var view: IslandView?

    /// Recording owns the island while true; hover may only peek when it is
    /// idle, and never interrupts an open island.
    private var recording = false
    private var hovering = false
    private var pendingPeek: DispatchWorkItem?
    private var pendingUnpeek: DispatchWorkItem?
    /// The island is expanded on the notes list (clicked).
    private var expanded = false
    private var pendingCollapse: DispatchWorkItem?
    private var mouseMonitors: [Any] = []

    /// The screen the panel currently sits on.
    private var screen: NSScreen?
    private var screenObserver: Any?
    /// Another notch app is running: we yield the resting state to it.
    private(set) var yielding = false
    private var appObservers: [Any] = []

    private func ensurePanel() -> (NSPanel, IslandView)? {
        if let panel, let view { return (panel, view) }
        guard let target = workingScreen() else { return nil }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 100, height: 100)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // .statusBar already sits above the menu bar, which is what a virtual
        // island needs; higher levels changed how the panel behaved.
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = IslandView(frame: panel.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        self.panel = panel
        self.view = view
        place(on: target, panel: panel, view: view)
        // Resident from now on: the closed pill is black over the black
        // housing (or invisible on other screens), so an on-screen panel costs
        // nothing visually, and hover has to work while nothing is recording.
        panel.orderFrontRegardless()
        installHoverMonitor(panel: panel, view: view)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        updateYielding()
        startVolumeWatcher()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.updateYielding() })
        }
        return (panel, view)
    }

    /// One notch: with Alcove & co. running, Noi is invisible at rest and
    /// stays above them while open. Level moves with the mode so a yielded
    /// island never sits over theirs when it has nothing to show.
    private func updateYielding() {
        let now = otherNotchAppRunning()
        guard now != yielding else { return }
        yielding = now
        guard let panel, let view else { return }
        panel.level = now ? .screenSaver : .statusBar
        view.setYielding(now)
        if now, view.state == .peek, !recording { view.layoutPill(.closed, animated: true) }
        if now, expanded { collapse() }
    }

    /// Size and position the panel for a screen. Wide and tall enough for the
    /// fully open island; the panel itself never resizes during an animation.
    private func place(on target: NSScreen, panel: NSPanel, view: IslandView) {
        let m = screenMetrics(of: target)
        let size = NSSize(
            width: m.cutoutWidth + (Island.overhang(.expanded) + Island.flare(.expanded)) * 2 + 40,
            height: m.safeAreaTop + Island.chinHeight(.expanded) + 20
        )
        let origin = NSPoint(
            x: target.frame.midX - size.width / 2,
            y: target.frame.maxY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        view.frame = NSRect(origin: .zero, size: size)
        view.configure(cutoutWidth: m.cutoutWidth, safeAreaTop: m.safeAreaTop, synthetic: m.synthetic, scale: target.backingScaleFactor)
        screen = target
    }

    /// Find the focused window's screen off-main and re-place if it differs.
    /// By the time the AX answer lands the island may already be open there —
    /// follow() only acts while closed, so a late answer never yanks an open
    /// island across displays; it corrects the next gesture instead.
    private func refineScreenAsync() {
        DispatchQueue.global(qos: .userInteractive).async {
            let s = focusedWindowScreen()
            DispatchQueue.main.async { [weak self] in self?.follow(s) }
        }
    }

    /// Move to `target` if idle. Never mid-gesture: an island that jumps
    /// screens while open is worse than one on the wrong screen.
    private func follow(_ target: NSScreen?) {
        guard let target, let panel, let view, target != screen,
              !recording, !expanded, view.state == .closed else { return }
        place(on: target, panel: panel, view: view)
    }

    private func screensChanged() {
        guard let panel, let view else { return }
        // Our screen may be gone or resized; re-place on the best one.
        let stillThere = screen.map { NSScreen.screens.contains($0) } ?? false
        if !stillThere || (!recording && !expanded && view.state == .closed) {
            if let t = stillThere ? screen : workingScreen() { place(on: t, panel: panel, view: view) }
        }
    }

    // MARK: Hover

    /// The panel keeps `ignoresMouseEvents = true` — accepting events would
    /// steal menu-bar clicks near the notch — so hover is derived from a
    /// global mouse-moved monitor instead of a tracking area. Global monitors
    /// don't see our own app's events; the local one covers that.
    private func installHoverMonitor(panel: NSPanel, view: IslandView) {
        let handler: (NSEvent) -> Void = { [weak self, weak panel, weak view] _ in
            guard let self, let panel, let view else { return }
            let mouse = NSEvent.mouseLocation
            // Hover has to work on whichever screen the pointer is on.
            if let s = self.screen, !s.frame.contains(mouse) {
                self.follow(NSScreen.screens.first { $0.frame.contains(mouse) })
            }
            let inWindow = panel.convertPoint(fromScreen: mouse)
            let inView = view.convert(inWindow, from: nil)
            self.setHovering(view.hoverRect.contains(inView))
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { e in handler(e); return e }) {
            mouseMonitors.append(local)
        }
        // A click on the island expands it to the notes list; a click
        // anywhere else while expanded collapses it. Global monitors see
        // clicks in other apps, which is exactly the case at rest.
        let click: (NSEvent) -> Void = { [weak self, weak panel, weak view] _ in
            guard let self, let panel, let view else { return }
            let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
            let inView = view.convert(inWindow, from: nil)
            let onIsland = view.hoverRect.contains(inView)
            if self.expanded {
                if !onIsland { self.collapse() }
            } else if onIsland, !self.recording, !self.yielding {
                self.expand()
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: click) {
            mouseMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { e in click(e); return e }) {
            mouseMonitors.append(l)
        }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53, self?.expanded == true { self?.collapse(); return nil }
            return e
        }) {
            mouseMonitors.append(k)
        }
    }

    private func setHovering(_ now: Bool) {
        guard now != hovering else { return }
        hovering = now
        guard !recording, !yielding, let view else { return }
        if now {
            pendingUnpeek?.cancel()
            // A dwell, so a pointer merely crossing the top edge on its way
            // to a menu doesn't make the island twitch.
            let peek = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, !self.recording else { return }
                self.view?.layoutPill(.peek, animated: true)
            }
            pendingPeek = peek
            DispatchQueue.main.asyncAfter(deadline: .now() + Island.hoverDwell, execute: peek)
        } else {
            pendingPeek?.cancel()
            guard view.state == .peek else { return }
            let unpeek = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, !self.recording, !self.expanded else { return }
                self.view?.layoutPill(.closed, animated: true)
            }
            pendingUnpeek = unpeek
            DispatchQueue.main.asyncAfter(deadline: .now() + Island.hoverExitGrace, execute: unpeek)
        }
    }

    // MARK: Notes list

    /// Open the inbox on the pointer's screen (a tray click — the pointer is
    /// where the user is), ignoring the yield rule.
    func showNotes() {
        guard let (_, view) = ensurePanel(), !recording else { return }
        follow(quickScreen())
        if expanded { collapse(); return }
        _ = view
        expand()
    }

    func expand() {
        guard let panel, let view, !expanded else { return }
        expanded = true
        pendingPeek?.cancel()
        pendingUnpeek?.cancel()
        // The panel takes the mouse only while expanded, so it never steals
        // menu-bar clicks at rest.
        panel.ignoresMouseEvents = false
        view.expandedTab.tab = view.mediaModel.playing ? .player : .notes
        view.expandedTab.onChange = { [weak self] in self?.relayoutExpanded() }
        view.notesModel.onCountChange = { [weak self] in self?.relayoutExpanded() }
        view.expandedChin = expandedChinHeight(for: view.expandedTab.tab, noteCount: view.notesModel.items.count)
        view.expandedOverhang = expandedOverhang(for: view.expandedTab.tab)
        view.setMode(.notes)
        view.layoutPill(.expanded, animated: true)
    }

    func collapse() {
        guard let panel, let view, expanded else { return }
        expanded = false
        panel.ignoresMouseEvents = true
        view.layoutPill(hovering ? .peek : .closed, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Island.shrinkDuration + 0.1) { [weak self] in
            guard let self, !self.recording, let v = self.view, v.state != .open else { return }
            v.setMode(.dictate)
        }
    }

    func setNotes(json: String) {
        guard let (_, view) = ensurePanel() else { return }
        view.notesModel.load(json: json)
        relayoutExpanded()
    }

    private var lastAnnouncedTitle: String?
    private var announceClose: DispatchWorkItem?
    private var hudClose: DispatchWorkItem?
    private var volumeWatcherStarted = false

    /// The Sound HUD: volume keys widen the resting pill into icon · Sound ·
    /// meter · value for a moment. Never over a gesture or another notch app.
    private func startVolumeWatcher() {
        guard !volumeWatcherStarted else { return }
        volumeWatcherStarted = true
        VolumeWatcher.start { [weak self] level, icon in
            self?.showVolume(level, icon: icon)
        }
    }

    private func showVolume(_ level: Float, icon: String) {
        guard let view, !recording, !expanded, !yielding,
              view.state == .closed || view.state == .peek else { return }
        view.showHUD(level: level, icon: icon)
        hudClose?.cancel()
        let close = DispatchWorkItem { [weak self] in self?.view?.hideHUD() }
        hudClose = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: close)
    }

    func setNowPlaying(json: String) {
        guard let (_, view) = ensurePanel() else { return }
        view.mediaModel.load(json: json)
        let m = view.mediaModel
        view.setMedia(available: m.available, playing: m.playing, artwork: m.artwork, accent: NSColor(m.accent))
        maybeAnnounce(view)
        // Media went away while the player was showing: fall back to notes.
        if expanded, view.expandedTab.tab == .player, !view.mediaModel.available {
            view.expandedTab.tab = .notes
            relayoutExpanded()
        }
    }

    /// A new track: drop the banner (or flip it if it's already up), then
    /// retract after a beat. Never over a gesture, never while yielding —
    /// Alcove announces its own songs.
    private func maybeAnnounce(_ view: IslandView) {
        let m = view.mediaModel
        let title = m.available ? m.title : nil
        defer { lastAnnouncedTitle = title }
        guard let title, m.playing, let prev = lastAnnouncedTitle, prev != title,
              !recording, !expanded, !yielding else { return }
        let mode = IslandMode.announce(title: title, artist: m.artist)
        if view.state == .open, view.mode.isAnnounce {
            view.announceSwap(mode)
        } else if view.state == .closed || view.state == .peek {
            view.setMode(mode)
            view.layoutPill(.open, animated: true)
        } else {
            return
        }
        announceClose?.cancel()
        let close = DispatchWorkItem { [weak self] in
            guard let self, !self.recording, !self.expanded,
                  self.view?.mode.isAnnounce == true else { return }
            self.view?.layoutPill(self.hovering ? .peek : .closed, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + Island.shrinkDuration + 0.1) { [weak self] in
                guard let self, self.view?.mode.isAnnounce == true,
                      self.view?.state != .open else { return }
                self.view?.setMode(.dictate)
            }
        }
        announceClose = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: close)
    }

    /// The card decides the expanded height; re-spring when it changes.
    func relayoutExpanded() {
        guard let view, expanded else { return }
        let h = expandedChinHeight(for: view.expandedTab.tab, noteCount: view.notesModel.items.count)
        let o = expandedOverhang(for: view.expandedTab.tab)
        guard h != view.expandedChin || o != view.expandedOverhang else { return }
        view.expandedChin = h
        view.expandedOverhang = o
        view.layoutPill(.expanded, animated: true)
    }

    /// The island works on every screen (virtual on non-notch ones); it only
    /// needs the safe-area APIs to tell them apart.
    func available() -> Bool {
        if #available(macOS 12.0, *) { return true }
        return false
    }

    func prepare() {
        _ = ensurePanel()
    }

    /// Open the island. Idempotent while open: the pipeline calls this again
    /// for each phase (recording → transcribing → processing), and re-opening
    /// would restart the timer and re-run the reveal.
    func show() {
        guard let (_, view) = ensurePanel() else { return }
        // Show NOW on a cheaply-chosen screen; where the text actually lands
        // (the focused window's screen, an AX query that can block) is found
        // in the background and only moves the island if it disagrees.
        follow(quickScreen())
        refineScreenAsync()
        pendingPeek?.cancel()
        pendingUnpeek?.cancel()
        announceClose?.cancel()
        if view.mode.isAnnounce { view.setMode(.dictate) }
        hudClose?.cancel()
        view.hideHUD()
        if expanded {
            expanded = false
            panel?.ignoresMouseEvents = true
        }
        guard !recording else { return }
        recording = true
        if view.mode.isRecording { view.startRecording() }
        view.layoutPill(.open, animated: true)
    }

    func setMode(_ m: IslandMode) {
        guard let (_, view) = ensurePanel() else { return }
        view.setMode(m)
    }

    func setClock(_ enabled: Bool) {
        guard let (_, view) = ensurePanel() else { return }
        view.clockEnabled = enabled
    }

    /// Show the outcome for a beat, then close. Opens first if needed, so a
    /// tap-refine that never recorded still gets its "Done".
    func finish(ok: Bool, label: String) {
        guard let (_, view) = ensurePanel() else { return }
        // "Done" may be held back until the armed hint has been readable;
        // the close waits the same amount, then a second on top.
        let wait = view.remainingArmedDwell() + 1.0
        view.setMode(.done(ok: ok, label: label))
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.view?.mode.isDone == true else { return }
            self.hide()
        }
    }

    func hide() {
        guard let view else { return }
        recording = false
        view.stopRecording()
        // The panel stays resident (hover needs it); only the pill collapses.
        // If the pointer is already resting on it, settle into the peek
        // rather than snapping shut under the cursor.
        view.layoutPill(hovering ? .peek : .closed, animated: true)
        // Once shut, forget the last mode so the next open — even another
        // "done" — lays out and animates fresh. setMode ignores same-mode
        // calls, so without this a second refine in a row would not replay
        // the completion mark.
        DispatchQueue.main.asyncAfter(deadline: .now() + Island.shrinkDuration + 0.1) { [weak self] in
            guard let self, !self.recording, let view = self.view, view.state != .open else { return }
            view.setMode(.dictate)
        }
    }

    func setLevel(_ level: CGFloat) {
        view?.setLevel(level)
    }
}

// MARK: - C interface
//
// Rust calls these from arbitrary threads; AppKit requires the main thread.

/// Pure (an OS-version check) and callable from any thread. It must NOT
/// hop to the main thread: Rust caches the answer in a OnceLock, and a
/// background caller holding that lock while waiting on a busy main thread
/// deadlocked startup once the main thread asked too.
@_cdecl("notch_overlay_available")
public func notch_overlay_available() -> Int32 {
    if #available(macOS 12.0, *) { return 1 }
    return 0
}

/// Put the island on screen at rest so hover works before the first
/// recording. Harmless to call more than once or on a notchless machine.
@_cdecl("notch_overlay_prepare")
public func notch_overlay_prepare() {
    DispatchQueue.main.async { IslandController.shared.prepare() }
}

@_cdecl("notch_overlay_show")
public func notch_overlay_show() {
    DispatchQueue.main.async { IslandController.shared.show() }
}

/// 0 dictate, 1 instruct, 2 transcribing, 3 refining. Call before show() for
/// a fresh open, or while open to cross-fade the content.
@_cdecl("notch_overlay_set_mode")
public func notch_overlay_set_mode(_ mode: Int32) {
    let m: IslandMode
    switch mode {
    case 1: m = .instruct
    case 4: m = .armed
    case 2: m = .working("Transcribing…", symbol: "text.alignleft")
    case 3: m = .working("Refining…", symbol: "sparkles")
    default: m = .dictate
    }
    DispatchQueue.main.async { IslandController.shared.setMode(m) }
}

/// Show or hide the small long-dictation clock (user setting).
@_cdecl("notch_overlay_set_clock")
public func notch_overlay_set_clock(_ enabled: Int32) {
    DispatchQueue.main.async { IslandController.shared.setClock(enabled != 0) }
}

/// The inbox as JSON: {"items":[{"id":1,"body":"…","when":"5m ago","where":"Safari · github.com","bundleId":"com.apple.Safari"}],"clearedToday":3}.
@_cdecl("notch_overlay_set_notes")
public func notch_overlay_set_notes(_ json: UnsafePointer<CChar>?) {
    let s = json.map { String(cString: $0) } ?? "[]"
    DispatchQueue.main.async { IslandController.shared.setNotes(json: s) }
}

/// Rust registers a callback for actions taken in the list:
/// action 1 = clear (done), 2 = archive, 3 = copy body to clipboard.
public typealias NoteActionCallback = @convention(c) (Int32, Int64) -> Void
nonisolated(unsafe) var noteActionCallback: NoteActionCallback?

@_cdecl("notch_overlay_set_note_callback")
public func notch_overlay_set_note_callback(_ cb: NoteActionCallback?) {
    noteActionCallback = cb
}

/// Show an outcome briefly, then close. 0 = failed, 1 = done, 2 = noted.
@_cdecl("notch_overlay_finish")
public func notch_overlay_finish(_ outcome: Int32) {
    let (ok, label): (Bool, String)
    switch outcome {
    case 2: (ok, label) = (true, "Noted")
    case 1: (ok, label) = (true, "Done")
    default: (ok, label) = (false, "Couldn't do that")
    }
    DispatchQueue.main.async { IslandController.shared.finish(ok: ok, label: label) }
}

/// Expand on the notes inbox on request (tray menu). Works while yielding to
/// another notch app: an explicit ask, unlike hover/click on the notch.
@_cdecl("notch_overlay_show_notes")
public func notch_overlay_show_notes() {
    DispatchQueue.main.async { IslandController.shared.showNotes() }
}

/// Now-playing JSON from Rust (media.rs); {} when nothing is playing.
@_cdecl("notch_overlay_set_now_playing")
public func notch_overlay_set_now_playing(_ json: UnsafePointer<CChar>?) {
    let s = json.map { String(cString: $0) } ?? "{}"
    DispatchQueue.main.async { IslandController.shared.setNowPlaying(json: s) }
}

/// Rust registers a callback for the player's transport:
/// 1 = toggle play/pause, 2 = next, 3 = previous, 4 = seek (arg = µs).
public typealias MediaActionCallback = @convention(c) (Int32, Int64) -> Void
nonisolated(unsafe) var mediaActionCallback: MediaActionCallback?

@_cdecl("notch_overlay_set_media_callback")
public func notch_overlay_set_media_callback(_ cb: MediaActionCallback?) {
    mediaActionCallback = cb
}

@_cdecl("notch_overlay_hide")
public func notch_overlay_hide() {
    DispatchQueue.main.async { IslandController.shared.hide() }
}

@_cdecl("notch_overlay_set_level")
public func notch_overlay_set_level(_ level: Float) {
    DispatchQueue.main.async { IslandController.shared.setLevel(CGFloat(level)) }
}


// MARK: - Notes list (SwiftUI)

struct NoteItem: Identifiable, Decodable, Equatable {
    let id: Int64
    var body: String
    var when: String
    /// "Safari · github.com" — where it was said. Optional.
    var `where`: String?
    var bundleId: String?
}

/// What Rust sends: the inbox (open notes) and today's cleared count.
struct NotesPayload: Decodable {
    var items: [NoteItem]
    var clearedToday: Int
}

final class NotesModel: ObservableObject {
    @Published var items: [NoteItem] = []
    @Published var clearedToday: Int = 0
    /// Rows mid-clear: the check blooms, then the row slides out.
    @Published var clearing: Set<Int64> = []
    /// Row that was just copied, for the brief "Copied" flash.
    @Published var copiedId: Int64?
    private var iconCache: [String: NSImage] = [:]

    func load(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(NotesPayload.self, from: data) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            // Keep rows that are animating out until the animation removes them.
            items = decoded.items + items.filter { clearing.contains($0.id) && !decoded.items.contains($0) }
            clearedToday = decoded.clearedToday
        }
    }

    /// Done means gone: the island is an inbox. Rust records `done_at`; the
    /// full list stays in Settings.
    /// Island re-measures the expanded height when the list changes.
    var onCountChange: (() -> Void)?
    func clear(_ n: NoteItem) {
        guard !clearing.contains(n.id) else { return }
        clearing.insert(n.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                self.items.removeAll { $0.id == n.id }
                self.clearedToday += 1
            }
            self.clearing.remove(n.id)
            noteActionCallback?(1, n.id)
            self.onCountChange?()
        }
    }

    func copy(_ n: NoteItem) {
        noteActionCallback?(3, n.id)
        withAnimation(.easeOut(duration: 0.15)) { copiedId = n.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.copiedId == n.id else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.copiedId = nil }
        }
    }

    func icon(for bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let cached = iconCache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleId] = img
        return img
    }
}

/// The inbox that sits inside the black island. Open notes only; clearing a
/// row (circle or swipe) checks it and slides it away; tapping a row copies
/// it — that's the thing you actually do with a note.
@available(macOS 14.0, *)
struct NotesListView: View {
    @ObservedObject var model: NotesModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .foregroundStyle(.white)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Notes")
                .font(.system(size: 13, weight: .semibold))
            if !model.items.isEmpty {
                Text("\(model.items.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .contentTransition(.numericText())
            }
            Spacer()
            if model.clearedToday > 0 {
                Text("\(model.clearedToday) cleared today")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("All clear")
                .font(.system(size: 13, weight: .semibold))
            Text(model.clearedToday > 0
                 ? "Say “note down…” while dictating to add one"
                 : "Hold your dictation key and say “note down…”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    private var list: some View {
        List {
            ForEach(model.items) { n in
                row(n)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.white.opacity(0.08))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { model.clear(n) } label: {
                            Label("Clear", systemImage: "checkmark")
                        }.tint(.green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { model.copy(n) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }.tint(.blue)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .transition(.opacity)
    }

    private func row(_ n: NoteItem) -> some View {
        let clearing = model.clearing.contains(n.id)
        let copied = model.copiedId == n.id
        return HStack(alignment: .top, spacing: 10) {
            Button { model.clear(n) } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(clearing ? 0 : 0.35), lineWidth: 1.2)
                    Circle()
                        .fill(Color.green)
                        .scaleEffect(clearing ? 1 : 0.2)
                        .opacity(clearing ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .scaleEffect(clearing ? 1 : 0.4)
                        .opacity(clearing ? 1 : 0)
                }
                .frame(width: 17, height: 17)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: clearing)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(n.body)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(clearing ? 0.4 : 1))
                    .strikethrough(clearing, color: .white.opacity(0.5))
                HStack(spacing: 5) {
                    if let icon = model.icon(for: n.bundleId) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    Text([n.where, n.when].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if copied {
                Text("Copied")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.copy(n) }
        .opacity(clearing ? 0.6 : 1)
    }
}


// MARK: - Expanded card: Now Playing · Notes

enum ExpandedCard { case player, notes }

/// Horizontal reach past the cutout per card: the player is a compact
/// Alcove-sized box, the notes list keeps the full width.
private func expandedOverhang(for tab: ExpandedCard) -> CGFloat {
    switch tab { case .player: return 56; case .notes: return Island.overhang(.expanded) }
}

/// Chin height per card: the player is a compact block; the inbox is as tall
/// as it needs to be (empty state is small), capped.
private func expandedChinHeight(for tab: ExpandedCard, noteCount: Int) -> CGFloat {
    switch tab {
    case .player: return 136
    case .notes:
        if noteCount == 0 { return 132 }
        let rows = CGFloat(min(noteCount, 5))
        return min(Island.chinHeight(.expanded), 44 + rows * 52 + 8)
    }
}

/// Which card is showing. A tiny observable so the SwiftUI switch and the
/// AppKit island (which owns the height) agree.
final class ExpandedTab: ObservableObject {
    @Published var tab: ExpandedCard = .notes { didSet { if tab != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
}

/// Now-playing state as Rust streams it (see media.rs). Artwork arrives only
/// when it changes (`artworkKey`), so we keep the last image.
final class NowPlayingModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var playing = false
    @Published var bundleId: String?
    @Published var durationMicros: Int64 = 0
    /// Elapsed at `timestampMicros` (epoch µs); the view extrapolates.
    @Published var elapsedMicros: Int64 = 0
    @Published var timestampMicros: Int64 = 0
    @Published var artwork: NSImage?
    @Published var accent: Color = .white
    private var artworkKey: UInt64 = 0

    var available: Bool { !title.isEmpty }

    func load(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        title = obj["title"] as? String ?? ""
        artist = obj["artist"] as? String ?? ""
        album = obj["album"] as? String ?? ""
        playing = obj["playing"] as? Bool ?? false
        bundleId = obj["bundleIdentifier"] as? String
        durationMicros = Self.int64(obj["durationMicros"])
        elapsedMicros = Self.int64(obj["elapsedTimeMicros"])
        timestampMicros = Self.int64(obj["timestampEpochMicros"])
        let key = Self.uint64(obj["artworkKey"])
        if key != artworkKey || (key != 0 && artwork == nil) {
            if let b64 = obj["artworkData"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d) {
                artwork = img
                accent = Self.dominantColor(of: img) ?? .white
                artworkKey = key
            } else if key == 0 {
                artwork = nil
                accent = .white
                artworkKey = 0
            }
        }
        if !available { artwork = nil; artworkKey = 0 }
    }

    /// Where playback is right now, in seconds.
    func elapsedNow(at date: Date) -> Double {
        var e = Double(elapsedMicros) / 1_000_000
        if playing, timestampMicros > 0 {
            e += date.timeIntervalSince1970 - Double(timestampMicros) / 1_000_000
        }
        return max(0, min(e, duration))
    }
    var duration: Double { Double(durationMicros) / 1_000_000 }

    private static func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }
    /// Never `UInt64(int64Value)`: a value above Int64.max comes through as
    /// negative and that conversion traps (it crashed the app once).
    private static func uint64(_ v: Any?) -> UInt64 {
        if let n = v as? NSNumber { return n.uint64Value }
        return 0
    }

    /// Average colour of the artwork, lifted a little so it reads on black.
    private static func dominantColor(of image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let extent = ci.extent
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: extent)]),
              let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        c = c.usingColorSpace(.deviceRGB) ?? c
        // Keep it vivid and light enough on black.
        let sat = min(1, c.saturationComponent * 1.3)
        let bri = max(0.7, c.brightnessComponent)
        return Color(NSColor(hue: c.hueComponent, saturation: sat, brightness: bri, alpha: 1))
    }
}

@available(macOS 14.0, *)
struct ExpandedView: View {
    @ObservedObject var notes: NotesModel
    @ObservedObject var media: NowPlayingModel
    @ObservedObject var tab: ExpandedTab

    private func switchCard() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            tab.tab = tab.tab == .player ? .notes : .player
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if tab.tab == .player && media.available {
                    NowPlayingView(model: media, onSwitch: switchCard)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    NotesListView(model: notes)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The player reaches notes from its transport row; the notes
            // card gets one quiet glyph back to the player.
            if media.available && tab.tab == .notes {
                Button { switchCard() } label: {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .padding(.trailing, 8)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

/// Alcove-style player: big artwork · title/artist · bars, thin timeline,
/// one tight transport row. No volume row — the card stays compact.
@available(macOS 14.0, *)
struct NowPlayingView: View {
    @ObservedObject var model: NowPlayingModel
    var onSwitch: () -> Void
    @State private var scrubbing: Double? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(model.artist.isEmpty ? model.album : model.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Bars(playing: model.playing, color: model.accent)
                    .frame(width: 18, height: 14)
            }
            timeline
            HStack {
                // A leading spacer the width of the trailing glyph, so the
                // transport cluster is truly centred.
                Color.clear.frame(width: 26, height: 26)
                Spacer()
                HStack(spacing: 26) {
                    transport("backward.fill", size: 15) { mediaActionCallback?(3, 0) }
                    transport(model.playing ? "pause.fill" : "play.fill", size: 21) { mediaActionCallback?(1, 0) }
                    transport("forward.fill", size: 15) { mediaActionCallback?(2, 0) }
                }
                Spacer()
                Button(action: onSwitch) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var artwork: some View {
        Group {
            if let img = model.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var timeline: some View {
        TimelineView(.periodic(from: .now, by: model.playing ? 0.5 : 60)) { ctx in
            let elapsed = scrubbing ?? model.elapsedNow(at: ctx.date)
            let total = max(model.duration, 0.001)
            HStack(spacing: 8) {
                Text(fmt(elapsed))
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 32, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(model.accent.opacity(0.9))
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, elapsed / total))))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            scrubbing = Double(max(0, min(1, g.location.x / geo.size.width))) * total
                        }
                        .onEnded { g in
                            let t = Double(max(0, min(1, g.location.x / geo.size.width))) * total
                            mediaActionCallback?(4, Int64(t * 1_000_000))
                            // Hold the scrubbed position until the next update lands.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scrubbing = nil }
                        })
                }
                .frame(height: 14)
                Text("-" + fmt(max(0, total - elapsed)))
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 36, alignment: .leading)
            }
        }
    }

    private func transport(_ name: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Four little bars that dance while playing (Alcove's glyph), in the
/// artwork's colour.
@available(macOS 14.0, *)
struct Bars: View {
    let playing: Bool
    let color: Color
    @State private var phase = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: playing ? (phase ? [10, 6, 13, 8][i] : [5, 12, 7, 11][i]) : 3)
                    .animation(playing ? .easeInOut(duration: 0.45 + Double(i) * 0.07).repeatForever(autoreverses: true) : .default, value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

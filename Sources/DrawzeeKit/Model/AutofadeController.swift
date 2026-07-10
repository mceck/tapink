import Foundation
import CoreGraphics

/// Owns the auto-fade lifecycle for objects committed while the mode is on:
/// each one waits out `AppSettings.autofadeDelaySeconds`, then animates out —
/// strokes are consumed along their own path from the first point to the last
/// (an invisible eraser retracing the original drawing motion), shapes and
/// text fade to transparent since they have no meaningful draw direction —
/// and is finally removed from the document for real.
///
/// Rendering stays out of here on purpose: canvases ask `progress(for:)`
/// mid-`draw` and apply the truncation/alpha themselves, so `DrawingDocument`
/// remains the single source of truth for what exists and this controller only
/// answers "how far erased is this object right now".
public final class AutofadeController {
    /// Along-the-path retract speed for strokes, clamped so a short dash
    /// doesn't blink out instantly and a screen-wide scribble doesn't take
    /// many seconds to unwind.
    private static let retractSpeed: CGFloat = 3000
    private static let minStrokeDuration: TimeInterval = 0.3
    private static let maxStrokeDuration: TimeInterval = 1.2
    private static let alphaFadeDuration: TimeInterval = 0.35

    private struct Pending {
        let timer: Timer
        let duration: TimeInterval
    }

    private struct Animating {
        let startedAt: Date
        let duration: TimeInterval
    }

    private var pending: [UUID: Pending] = [:]
    private var animating: [UUID: Animating] = [:]
    private var animationTimer: Timer?

    private let document: DrawingDocument
    /// Fired on every animation tick and whenever fade state is dropped, so
    /// canvases repaint objects at their current erase progress.
    public var onNeedsRedraw: (() -> Void)?
    public private(set) var isEnabled = false

    public init(document: DrawingDocument) {
        self.document = document
    }

    /// Turning the mode off keeps whatever is still on screen: pending and
    /// mid-animation objects revert to fully visible and permanent, matching
    /// the intuition that "auto-fade off" means "my drawings stay".
    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled { cancelAll() }
    }

    /// Call for every newly committed object. Ignored while the mode is off —
    /// which also gives "stroke started before enabling, finished after" the
    /// right behavior for free, since the fade clock always starts at commit
    /// (mouse-up) time, not at mouse-down.
    public func scheduleFade(for object: DrawingObject) {
        guard isEnabled else { return }
        let objectID = object.id
        let timer = Timer(timeInterval: AppSettings.shared.autofadeDelaySeconds, repeats: false) { [weak self] _ in
            self?.beginAnimating(objectID)
        }
        // `.common` keeps the delay and the animation ticking during mouse
        // drags — `.default`-mode timers pause for the entire duration of any
        // drag (the run loop switches to event-tracking mode), which would
        // visibly freeze every fade for as long as the user keeps drawing.
        RunLoop.main.add(timer, forMode: .common)
        pending[objectID] = Pending(timer: timer, duration: AutofadeController.eraseDuration(for: object))
    }

    /// Erase progress in 0...1 for an object mid-animation, or nil when the
    /// object should render fully visible (not scheduled, or still waiting
    /// out the delay).
    public func progress(for objectID: UUID) -> CGFloat? {
        guard let entry = animating[objectID] else { return nil }
        return min(1, CGFloat(Date().timeIntervalSince(entry.startedAt) / entry.duration))
    }

    /// Drops state for objects that left the document some other way (undo,
    /// clear), so a stale timer can't erase an object revived later by redo.
    public func pruneRemovedObjects(keeping existingIDs: Set<UUID>) {
        for (id, entry) in pending where !existingIDs.contains(id) {
            entry.timer.invalidate()
            pending[id] = nil
        }
        for id in animating.keys where !existingIDs.contains(id) {
            animating[id] = nil
        }
        stopAnimationTimerIfIdle()
    }

    /// Exiting draw mode removes everything still scheduled or mid-animation
    /// outright: those objects were already promised to disappear, and
    /// finishing the erase invisibly beats having them resurrect whole in the
    /// next session.
    public func finishImmediately() {
        let ids = Array(pending.keys) + Array(animating.keys)
        pending.values.forEach { $0.timer.invalidate() }
        pending.removeAll()
        animating.removeAll()
        stopAnimationTimerIfIdle()
        // State is cleared before touching the document: each `remove` fires
        // `onChange`, which re-enters here via `pruneRemovedObjects`.
        ids.forEach { document.remove(id: $0) }
    }

    private func cancelAll() {
        pending.values.forEach { $0.timer.invalidate() }
        pending.removeAll()
        animating.removeAll()
        stopAnimationTimerIfIdle()
        onNeedsRedraw?()
    }

    private func beginAnimating(_ objectID: UUID) {
        guard let entry = pending.removeValue(forKey: objectID) else { return }
        animating[objectID] = Animating(startedAt: Date(), duration: entry.duration)
        startAnimationTimerIfNeeded()
    }

    private func startAnimationTimerIfNeeded() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimationTimerIfIdle() {
        guard animating.isEmpty else { return }
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        let now = Date()
        let finished = animating.keys.filter { id in
            guard let entry = animating[id] else { return false }
            return now.timeIntervalSince(entry.startedAt) >= entry.duration
        }
        // Same re-entrancy rule as `finishImmediately`: clear state first,
        // then mutate the document.
        finished.forEach { animating[$0] = nil }
        stopAnimationTimerIfIdle()
        finished.forEach { document.remove(id: $0) }
        onNeedsRedraw?()
    }

    static func eraseDuration(for object: DrawingObject) -> TimeInterval {
        switch object {
        case .stroke(let stroke):
            let length = StrokeGeometry.length(of: stroke.points)
            return min(maxStrokeDuration, max(minStrokeDuration, TimeInterval(length / retractSpeed)))
        case .shape, .text:
            return alphaFadeDuration
        }
    }
}

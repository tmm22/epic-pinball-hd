import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Small always-visible layer over the running table (unlike `GameOverlayView`, it never takes
/// input): the brief confirmation after a screenshot and the optional performance overlay.
@MainActor
@Observable
final class StatusHUDModel {
    /// One-line confirmation, shown for `toastSeconds` (`flash`).
    private(set) var toast: String?
    /// Performance overlay lines; nil = overlay off.
    var perf: [String]?

    @ObservationIgnored private var toastToken = 0
    static let toastSeconds = 2.5

    func flash(_ text: String) {
        toast = text
        toastToken += 1
        let t = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastSeconds) { [weak self] in
            MainActor.assumeIsolated { if self?.toastToken == t { self?.toast = nil } }
        }
    }
}

struct StatusHUDView: View {
    @Bindable var model: StatusHUDModel
    /// Cabinet: turned with the picture (OverlayRotation.swift).
    var orientation = OverlayOrientation()
    var body: some View {
        ZStack {
            if let lines = model.perf {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element) }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.65)))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            }
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.7), lineWidth: 1))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .allowsHitTesting(false)
        .cabinetRotated(orientation.rotation)
    }
}

/// Hosting view that lets every click through to the views below (the game view, the menus).
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Display FPS, simulation time per display frame, and keyboard flipper latency, summarised
/// every `period` seconds for the performance overlay. Times are `CACurrentMediaTime` seconds
/// (the timebase of `NSEvent.timestamp` and `CAMetalDrawable.presentedTime`).
struct PerfMeter {
    var period = 0.5
    private var windowStart: Double?
    private var displayFrames = 0
    private var simTotal = 0.0, simMax = 0.0
    private var simFrames = 0
    /// Key event time of the newest flipper press not yet seen by a simulation frame.
    private var pendingKey: Double?
    /// Latest measurements (ms): key -> first simulation frame that sampled it, -> its frame on screen.
    private(set) var lastKeyToSim: Double?
    private(set) var lastKeyToPresent: Double?
    private(set) var summary: [String] = []

    init(period: Double = 0.5) { self.period = period }

    /// A flipper key went down at `time` (the event's timestamp).
    mutating func flipperPressed(at time: Double) { pendingKey = time }

    /// After `advance`: `ran` original frames took `simSeconds` of CPU, at `now`, with `flipperHeld`
    /// in the sampled input. Returns the key time when this frame is the first to apply a press
    /// (so the caller can follow the frame to the screen).
    mutating func frame(now: Double, ran: Int, simSeconds: Double, flipperHeld: Bool) -> Double? {
        displayFrames += 1
        simTotal += simSeconds
        simMax = max(simMax, simSeconds)
        simFrames += ran
        var applied: Double?
        if let k = pendingKey, ran > 0, flipperHeld {
            pendingKey = nil
            let d = now - k
            if d >= 0, d < 1 { lastKeyToSim = d * 1000; applied = k }
        }
        guard let start = windowStart else { windowStart = now; return applied }
        let span = now - start
        if span >= period {
            let fps = Double(displayFrames) / span
            summary = [
                String(format: "display %5.1f fps", fps),
                String(format: "sim %5.2f ms/frame avg, %5.2f max (%d game frames)",
                       simTotal / Double(max(displayFrames, 1)) * 1000, simMax * 1000, simFrames),
                "flipper key to sim " + (lastKeyToSim.map { String(format: "%.1f ms", $0) } ?? "n/a")
                    + ", to screen " + (lastKeyToPresent.map { String(format: "%.1f ms", $0) } ?? "n/a"),
            ]
            windowStart = now
            displayFrames = 0; simTotal = 0; simMax = 0; simFrames = 0
        }
        return applied
    }

    /// The drawable of the frame that first applied the key at `keyTime` was shown at `presented`.
    mutating func presented(keyTime: Double, at presented: Double) {
        let d = presented - keyTime
        if presented > 0, d >= 0, d < 1 { lastKeyToPresent = d * 1000 }
    }
}

import SwiftUI
import ContextCore

/// Horizontal pointer direction for the buddy's eyes, -1 (left) … 1 (right).
/// Kept apart from the island state so mouse moves redraw only the buddy.
@MainActor final class NotchLook: ObservableObject {
    @Published var x: CGFloat = 0
}

/// Context Desk's own island character: a coral squircle whose face follows the agents.
/// Sleepy when idle, reading while they work, wide-eyed and wiggling when one needs the user,
/// happy with a jump when a turn finishes. Drawn in a Canvas from the clock alone.
struct DeskBuddy: View {
    enum Mood { case idle, working, waiting, happy }
    let mood: Mood
    let size: CGFloat
    var celebratedAt: Date?
    @ObservedObject var look: NotchLook
    var paused = false

    init(summary: NotchSummary, size: CGFloat, celebratedAt: Date?, look: NotchLook, paused: Bool) {
        mood = switch summary {
        case .idle: .idle
        case .working: .working
        case .waiting: .waiting
        case .finished: .happy
        }
        self.size = size; self.celebratedAt = celebratedAt; self.look = look; self.paused = paused
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: mood == .idle ? 1.0 / 15 : 1.0 / 30, paused: paused)) { context in
            Canvas { canvas, area in draw(in: &canvas, area: area, now: context.date) }
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .accessibilityLabel(L10n.text("Статус агентов", "Agent status"))
    }

    private func draw(in canvas: inout GraphicsContext, area: CGSize, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        let s = size
        var dy: CGFloat = 0, angle: CGFloat = 0, scale: CGFloat = 1
        switch mood {
        case .idle: scale = 1 + CGFloat(sin(t * 1.6)) * 0.03
        case .working: dy = CGFloat(sin(t * 6)) * s * 0.04
        case .waiting:
            let phase = t.truncatingRemainder(dividingBy: 1.6)
            if phase < 0.45 { angle = CGFloat(sin(phase / 0.45 * .pi * 3)) * 0.16 }
        case .happy: dy = -abs(CGFloat(sin(t * 3))) * s * 0.05
        }
        if let celebratedAt {
            let elapsed = now.timeIntervalSince(celebratedAt)
            if elapsed >= 0, elapsed < 0.9 { dy -= abs(CGFloat(sin(elapsed * .pi * 2.2))) * s * 0.35 * CGFloat(1 - elapsed / 0.9) }
        }

        let center = CGPoint(x: area.width / 2, y: area.height / 2 + dy + s * 0.05)
        if mood == .waiting {
            let glow = CGFloat(t.truncatingRemainder(dividingBy: 1.2) / 1.2)
            let radius = s * (0.6 + glow * 0.35)
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(.orange.opacity(0.45 * Double(1 - glow))))
        }
        canvas.translateBy(x: center.x, y: center.y)
        canvas.rotate(by: .radians(angle))
        canvas.scaleBy(x: scale, y: scale)

        let side = s * 0.92
        let body = Path(roundedRect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side), cornerRadius: side * 0.38, style: .continuous)
        let top = mood == .waiting ? Color(red: 1, green: 0.66, blue: 0.38) : Color(red: 0.96, green: 0.64, blue: 0.49)
        let bottom = mood == .waiting ? Color(red: 0.95, green: 0.45, blue: 0.2) : Color(red: 0.85, green: 0.46, blue: 0.32)
        canvas.fill(body, with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: CGPoint(x: 0, y: -side / 2), endPoint: CGPoint(x: 0, y: side / 2)))

        let ink = Color(white: 0.13)
        let eyeY = -s * 0.06, spread = s * 0.2
        let gaze: CGFloat = mood == .working ? CGFloat(sin(t * 2.2)) * s * 0.07 : look.x * s * 0.08
        for side in [-1.0, 1.0] as [CGFloat] {
            let x = side * spread + gaze
            switch mood {
            case .idle:
                var lid = Path()
                lid.move(to: CGPoint(x: x - s * 0.08, y: eyeY))
                lid.addQuadCurve(to: CGPoint(x: x + s * 0.08, y: eyeY), control: CGPoint(x: x, y: eyeY + s * 0.06))
                canvas.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: max(1.2, s * 0.07), lineCap: .round))
            case .happy:
                var arc = Path()
                arc.move(to: CGPoint(x: x - s * 0.08, y: eyeY + s * 0.04))
                arc.addQuadCurve(to: CGPoint(x: x + s * 0.08, y: eyeY + s * 0.04), control: CGPoint(x: x, y: eyeY - s * 0.1))
                canvas.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: max(1.2, s * 0.07), lineCap: .round))
            case .working, .waiting:
                let blinkEvery = mood == .waiting ? 5.3 : 3.7
                let blinking = (t + Double(side) * 0.02).truncatingRemainder(dividingBy: blinkEvery) < 0.13
                let width = s * (mood == .waiting ? 0.15 : 0.12)
                let height = s * (mood == .waiting ? 0.3 : 0.24) * (blinking ? 0.15 : 1)
                canvas.fill(Path(roundedRect: CGRect(x: x - width / 2, y: eyeY - height / 2, width: width, height: height), cornerRadius: width / 2),
                            with: .color(ink))
                if mood == .waiting, !blinking {
                    let dot = width * 0.4
                    canvas.fill(Path(ellipseIn: CGRect(x: x - width * 0.15, y: eyeY - height * 0.32, width: dot, height: dot)), with: .color(.white))
                }
            }
        }
        let mouthY = s * 0.17
        switch mood {
        case .waiting:
            let o = s * 0.09
            canvas.stroke(Path(ellipseIn: CGRect(x: gaze * 0.5 - o / 2, y: mouthY - o / 2, width: o, height: o * 1.1)),
                          with: .color(ink), lineWidth: max(1, s * 0.055))
        case .happy:
            var smile = Path()
            smile.move(to: CGPoint(x: -s * 0.1, y: mouthY - s * 0.02))
            smile.addQuadCurve(to: CGPoint(x: s * 0.1, y: mouthY - s * 0.02), control: CGPoint(x: 0, y: mouthY + s * 0.1))
            canvas.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: max(1.1, s * 0.06), lineCap: .round))
            for side in [-1.0, 1.0] as [CGFloat] {
                canvas.fill(Path(ellipseIn: CGRect(x: side * s * 0.3 - s * 0.06, y: mouthY - s * 0.06, width: s * 0.12, height: s * 0.07)),
                            with: .color(.pink.opacity(0.7)))
            }
        case .idle, .working: break
        }
    }
}

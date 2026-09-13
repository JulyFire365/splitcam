import SwiftUI

/// Two optical portals move through SplitCam's three compositions in a 12s loop.
/// Vector drawing avoids video decoding and scales to every screen size.
struct ProHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(startedAt)
            Canvas { context, size in drawScene(context: &context, size: size, time: time) }
        }
        .background(Color(red: 0.035, green: 0.035, blue: 0.075))
        .overlay(alignment: .bottom) {
            HStack(spacing: 7) {
                Text("SPLITCAM").tracking(3)
                Text("PRO").tracking(1.4)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.13), in: Capsule())
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.8)).padding(.bottom, 27)
        }
        .accessibilityHidden(true)
    }

    private func drawScene(context: inout GraphicsContext, size: CGSize, time: Double) {
        let unit = min(size.width / 390, size.height / 230)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.43)
        let cyan = Color(red: 0.24, green: 0.79, blue: 1)
        let violet = Color(red: 0.66, green: 0.43, blue: 1)
        let cycle = time.truncatingRemainder(dividingBy: 12) / 4
        let index = Int(cycle)
        let progress = min(1, (cycle - Double(index)) / 0.45)
        let blend = progress * progress * (3 - 2 * progress)
        // Each pair is (x offset, y offset, radius); hold each composition briefly.
        let poses: [[(Double, Double, Double)]] = [
            [(-54, 0, 57), (54, 0, 57)],
            [(0, -32, 49), (0, 37, 49)],
            [(-13, -4, 72), (59, 35, 29)]
        ]
        let from = poses[index]
        let to = poses[(index + 1) % poses.count]
        for i in 0..<74 {
            let angle = Double(i) * 2.39996 + time * (i.isMultiple(of: 2) ? 0.07 : -0.045)
            let orbit = (92 + Double(i % 9) * 8) * unit
            let point = CGPoint(x: center.x + cos(angle) * orbit * 1.5, y: center.y + sin(angle) * orbit * 0.64)
            let radius = (i.isMultiple(of: 11) ? 1.8 : 0.8) * unit
            let dot = Path(ellipseIn: CGRect(x: point.x, y: point.y, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color((i.isMultiple(of: 2) ? cyan : violet).opacity(0.16 + Double(i % 5) * 0.09)))
        }
        for lens in 0..<2 {
            let x = from[lens].0 + (to[lens].0 - from[lens].0) * blend
            let y = from[lens].1 + (to[lens].1 - from[lens].1) * blend
            let radius = (from[lens].2 + (to[lens].2 - from[lens].2) * blend) * unit
            let point = CGPoint(x: center.x + x * unit, y: center.y + y * unit)
            drawLens(context: &context, center: point, radius: radius, color: lens == 0 ? cyan : violet, time: time + Double(lens) * 3)
        }
        let frame = CGRect(x: center.x - 133 * unit, y: center.y - 82 * unit, width: 266 * unit, height: 164 * unit)
        for corner in 0..<4 {
            let x = corner.isMultiple(of: 2) ? frame.minX : frame.maxX
            let y = corner < 2 ? frame.minY : frame.maxY
            let dx: CGFloat = corner.isMultiple(of: 2) ? 12 * unit : -12 * unit
            let dy: CGFloat = corner < 2 ? 12 * unit : -12 * unit
            var path = Path()
            path.move(to: CGPoint(x: x + dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy))
            context.stroke(path, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    private func drawLens(context: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color, time: Double) {
        let halo = Path(ellipseIn: CGRect(x: center.x - radius * 1.55, y: center.y - radius * 1.55, width: radius * 3.1, height: radius * 3.1))
        context.fill(halo, with: .radialGradient(Gradient(colors: [color.opacity(0.24), .clear]), center: center, startRadius: radius * 0.2, endRadius: radius * 1.55))
        let disk = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(disk, with: .radialGradient(Gradient(colors: [.black, color.opacity(0.18), .black.opacity(0.8)]), center: center, startRadius: 0, endRadius: radius))
        for ring in 0..<9 {
            let r = radius * (0.34 + Double(ring) * 0.082)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .conicGradient(Gradient(colors: [color.opacity(0.12), color.opacity(0.85), .white.opacity(0.8), color.opacity(0.1), color.opacity(0.65), color.opacity(0.12)]), center: center, angle: .radians(time * 0.15 + Double(ring) * 0.2)), lineWidth: ring == 8 ? 2 : 1)
        }
        let glint = CGPoint(x: center.x - radius * 0.42, y: center.y - radius * 0.48)
        context.fill(Path(ellipseIn: CGRect(x: glint.x, y: glint.y, width: radius * 0.20, height: radius * 0.08)), with: .color(.white.opacity(0.78)))
    }
}

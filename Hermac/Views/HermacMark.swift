import SwiftUI

/// The same single-wing curve is used by the native AppIcon.icon artwork.
struct HermacSymbolShape: Shape {
    var openness: Double = 1

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var wing = Path()
        wing.move(to: .zero)
        wing.addCurve(to: CGPoint(x: -104, y: -270),
                      control1: CGPoint(x: -130, y: -35), control2: CGPoint(x: -112, y: -180))
        wing.addCurve(to: CGPoint(x: -108, y: -370),
                      control1: CGPoint(x: -104, y: -328), control2: CGPoint(x: -113, y: -354))
        wing.addQuadCurve(to: CGPoint(x: -103, y: -374), control: CGPoint(x: -111, y: -377))
        wing.addCurve(to: CGPoint(x: 53, y: -226),
                      control1: CGPoint(x: -10, y: -347), control2: CGPoint(x: 72, y: -291))
        wing.addCurve(to: CGPoint(x: -26, y: -61),
                      control1: CGPoint(x: 36, y: -159), control2: CGPoint(x: -44, y: -128))
        wing.addCurve(to: .zero,
                      control1: CGPoint(x: -18, y: -25), control2: CGPoint(x: -4, y: -6))
        wing.closeSubpath()

        // Each wing narrows and shortens about its own fixed root-to-tip axis.
        // This changes the individual silhouettes, rather than scaling the logo.
        let amount = min(1, max(0, openness))
        let across = 0.48 + 0.52 * amount
        let along = 0.82 + 0.18 * amount
        let axisX = -103.0, axisY = -374.0
        let lengthSquared = axisX * axisX + axisY * axisY
        let a = (along * axisX * axisX + across * axisY * axisY) / lengthSquared
        let b = (along - across) * axisX * axisY / lengthSquared
        let d = (along * axisY * axisY + across * axisX * axisX) / lengthSquared
        let fold = CGAffineTransform(a: a, b: b, c: b, d: d, tx: 0, ty: 0)
        let scale = min(rect.width, rect.height) / 1024

        var symbol = Path()
        for index in 0..<6 {
            let transform = fold
                .concatenating(CGAffineTransform(rotationAngle: Double(index) * .pi / 3))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
            symbol.addPath(wing, transform: transform)
        }
        return symbol
    }
}

enum HermacMarkMotion {
    static let rotationPeriod: TimeInterval = 6
    static let foldPeriod: TimeInterval = 2.4

    struct Sample {
        let rotationDegrees: Double
        let openness: Double
    }

    static func sample(elapsed: TimeInterval) -> Sample {
        let time = max(0, elapsed)
        return Sample(
            rotationDegrees: time.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod * 360,
            openness: 0.5 + 0.5 * cos(time / foldPeriod * 2 * .pi)
        )
    }
}

struct HermacMark: View {
    var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStart = Date()
    private let glassCanvas: CGFloat = 128

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            Group {
                if isAnimating && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let sample = HermacMarkMotion.sample(elapsed: context.date.timeIntervalSince(animationStart))
                        mark(openness: sample.openness)
                            .rotationEffect(.degrees(sample.rotationDegrees))
                    }
                } else {
                    mark(openness: 1)
                }
            }
            .frame(width: glassCanvas, height: glassCanvas)
            .scaleEffect(size / glassCanvas)
            .frame(width: size, height: size)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .clipped()
        .allowsHitTesting(false)
        .onChange(of: isAnimating) { _, active in
            if active { animationStart = Date() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isAnimating ? "Hermes 正在思考" : "Hermac 图标")
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func mark(openness: Double) -> some View {
        let shape = HermacSymbolShape(openness: openness)
        if isAnimating {
            // Small status indicators use one vector layer. The native glass
            // surface adds a separate outline that does not scale with it.
            shape
                .fill(Color.blue.opacity(0.72))
                .frame(width: glassCanvas, height: glassCanvas)
        } else {
            shape
                .fill(Color.blue.opacity(0.36))
                .frame(width: glassCanvas, height: glassCanvas)
                .glassEffect(.clear.tint(.blue.opacity(0.2)), in: shape)
        }
    }
}

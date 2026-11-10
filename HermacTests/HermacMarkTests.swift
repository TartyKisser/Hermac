import CoreGraphics
import XCTest
@testable import Hermac

@MainActor
final class HermacMarkTests: XCTestCase {
    private let frame = CGRect(x: 13, y: 7, width: 128, height: 96)

    private func wingPoints(_ path: CGPath) -> [[CGPoint]] {
        var wings: [[CGPoint]] = []
        path.applyWithBlock { element in
            let element = element.pointee
            switch element.type {
            case .moveToPoint:
                wings.append([element.points[0]])
            case .addLineToPoint:
                wings[wings.count - 1].append(element.points[0])
            case .addQuadCurveToPoint:
                wings[wings.count - 1].append(contentsOf: [element.points[0], element.points[1]])
            case .addCurveToPoint:
                wings[wings.count - 1].append(contentsOf: [element.points[0], element.points[1], element.points[2]])
            case .closeSubpath:
                break
            @unknown default:
                XCTFail("Unexpected path element")
            }
        }
        return wings
    }

    func testSixWingsShareRootAndRotateInExactSixtyDegreeSteps() {
        for openness in [0.0, 0.5, 1.0] {
            let wings = wingPoints(HermacSymbolShape(openness: openness).path(in: frame).cgPath)
            XCTAssertEqual(wings.count, 6)
            guard wings.count == 6 else { return }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            for (index, wing) in wings.enumerated() {
                XCTAssertEqual(wing.count, wings[0].count)
                XCTAssertEqual(wing[0].x, center.x, accuracy: 0.00001)
                XCTAssertEqual(wing[0].y, center.y, accuracy: 0.00001)
                let angle = Double(index) * .pi / 3
                for (point, base) in zip(wing, wings[0]) {
                    let x = base.x - center.x, y = base.y - center.y
                    let expectedX = center.x + x * cos(angle) - y * sin(angle)
                    let expectedY = center.y + x * sin(angle) + y * cos(angle)
                    XCTAssertEqual(point.x, expectedX, accuracy: 0.00001)
                    XCTAssertEqual(point.y, expectedY, accuracy: 0.00001)
                }
            }
        }
    }

    func testFoldingChangesWingProportionsWithoutMovingSharedRoot() {
        let open = wingPoints(HermacSymbolShape(openness: 1).path(in: frame).cgPath)[0]
        let closed = wingPoints(HermacSymbolShape(openness: 0).path(in: frame).cgPath)[0]
        XCTAssertEqual(open.count, closed.count)
        XCTAssertEqual(open[0], closed[0])

        // Uniformly scaling a spinner preserves its aspect ratio. Folding a wing
        // must alter its width relative to its length instead.
        func aspect(_ points: [CGPoint]) -> CGFloat {
            let width = points.map(\.x).max()! - points.map(\.x).min()!
            let height = points.map(\.y).max()! - points.map(\.y).min()!
            return width / height
        }
        XCTAssertGreaterThan(abs(aspect(open) - aspect(closed)), 0.04)
    }

    func testAllFoldingStatesFitInsideNonSquareFrame() {
        for openness in stride(from: 0.0, through: 1.0, by: 0.1) {
            let bounds = HermacSymbolShape(openness: openness).path(in: frame).boundingRect
            XCTAssertTrue(frame.contains(bounds), "Clipped at openness \(openness): \(bounds)")
        }
    }

    func testRotationAndFoldingHaveIndependentContinuousCycles() {
        let start = HermacMarkMotion.sample(elapsed: 0)
        let afterFold = HermacMarkMotion.sample(elapsed: 2.4)
        let afterRotation = HermacMarkMotion.sample(elapsed: 6)
        XCTAssertEqual(start.openness, afterFold.openness, accuracy: 0.00001)
        XCTAssertGreaterThan(abs(start.rotationDegrees - afterFold.rotationDegrees), 30)
        XCTAssertEqual(start.rotationDegrees, afterRotation.rotationDegrees, accuracy: 0.00001)
        XCTAssertGreaterThan(abs(start.openness - afterRotation.openness), 0.5)

        let samples = stride(from: 0.0, through: 12.0, by: 0.1).map {
            HermacMarkMotion.sample(elapsed: $0)
        }
        XCTAssertTrue(samples.allSatisfy { $0.openness.isFinite && (0...1).contains($0.openness) })
        XCTAssertTrue(samples.allSatisfy { $0.rotationDegrees.isFinite && (0..<360).contains($0.rotationDegrees) })
    }
}

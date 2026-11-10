import AppKit
import SwiftUI

/// A native popover material fills the window, including its transparent
/// titlebar; the hosted content stays below AppKit's titlebar layout guide.
@MainActor
final class FloatingPanelContentView: NSView {
    private let material = NSVisualEffectView()
    private let hostedView: NSView
    private var hostedConstraints: [NSLayoutConstraint] = []

    init<Content: View>(rootView: Content, materialVisible: Bool) {
        hostedView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.isHidden = !materialVisible
        material.translatesAutoresizingMaskIntoConstraints = false
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        addSubview(hostedView)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateContentLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentLayout()
    }

    func setMaterialVisible(_ visible: Bool) {
        material.isHidden = !visible
        updateContentLayout()
    }

    private func updateContentLayout() {
        NSLayoutConstraint.deactivate(hostedConstraints)
        if let window, window.styleMask.contains(.fullSizeContentView),
           let guide = window.contentLayoutGuide as? NSLayoutGuide {
            hostedConstraints = [
                hostedView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: guide.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
            ]
        } else {
            hostedConstraints = [
                hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
        }
        NSLayoutConstraint.activate(hostedConstraints)
    }
}

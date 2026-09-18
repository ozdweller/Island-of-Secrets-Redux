import AppKit

/// Pops Grandpa's map into its own lightweight reference window,
/// separate from the main game window, so the player can keep it open
/// alongside the game while they play. A singleton: pressing the "Map"
/// button again just re-reveals (and repositions) the same window
/// instead of spawning duplicates.
///
/// The map is shown in an NSScrollView with magnification enabled, so
/// the player can pinch-zoom or scroll-wheel-zoom directly, plus three
/// explicit buttons (-, Reset Zoom, +) for anyone who'd rather click.
/// "Reset Zoom" returns to a fit-to-window scale, recomputed from
/// whatever size the window currently is (so resizing the window and
/// hitting Reset just re-fits, rather than snapping to a fixed number).
final class MapWindowController: NSWindowController {
    static let shared = MapWindowController()

    private var didLoadImage = false
    private weak var scrollView: NSScrollView?
    private var mapImageSize: NSSize = .zero
    private static let zoomStep: CGFloat = 1.25

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Grandpa's Map"
        // Keep the window (and its loaded image) around after the
        // player closes it, rather than tearing it down -- reopening
        // should be instant, not a re-decode of the image every time.
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the map window, positioned just outside the edge of
    /// `mainWindow` (to its right, or its left if there's no room) so it
    /// reads as a companion window rather than something covering the
    /// game. Falls back to the app's default window placement if no
    /// reference window is available.
    func show(nextTo mainWindow: NSWindow?) {
        guard let window = self.window else { return }
        if !didLoadImage {
            didLoadImage = true
            loadImage(into: window)
        }
        if let mainWindow, let screen = mainWindow.screen ?? NSScreen.main {
            positionAdjacent(window, to: mainWindow, on: screen)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func loadImage(into window: NSWindow) {
        guard let image = RoomArt.mapImage() else {
            showMissingImagePlaceholder(in: window)
            return
        }

        let container = NSView()

        let zoomOutButton = NSButton(title: "\u{2212}", target: self, action: #selector(zoomOut))
        zoomOutButton.bezelStyle = .rounded
        zoomOutButton.toolTip = "Zoom out"

        let resetButton = NSButton(title: "Reset Zoom", target: self, action: #selector(zoomReset))
        resetButton.bezelStyle = .rounded
        resetButton.toolTip = "Fit the whole map to the window"

        let zoomInButton = NSButton(title: "+", target: self, action: #selector(zoomIn))
        zoomInButton.bezelStyle = .rounded
        zoomInButton.toolTip = "Zoom in"

        let controlsBar = NSStackView(views: [zoomOutButton, resetButton, zoomInButton])
        controlsBar.orientation = .horizontal
        controlsBar.spacing = 8
        controlsBar.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView(image: image)
        // We drive the effective size entirely through the scroll
        // view's magnification, not SwiftUI-style content scaling, so
        // the image view itself just holds the image at native size.
        imageView.imageScaling = .scaleNone
        imageView.frame = NSRect(origin: .zero, size: image.size)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.documentView = imageView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scrollView
        self.mapImageSize = image.size

        container.addSubview(controlsBar)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            controlsBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            controlsBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: controlsBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container

        // Size the window generously (capped so it comfortably fits
        // beside the game window), then fit the image to whatever
        // space that leaves for the scroll view.
        let maxHeight: CGFloat = 900
        let maxWidth: CGFloat = 720
        let controlsBarHeight: CGFloat = 44
        let aspect = image.size.width / max(image.size.height, 1)
        var imageAreaHeight = maxHeight - controlsBarHeight
        var width = imageAreaHeight * aspect
        if width > maxWidth {
            width = maxWidth
            imageAreaHeight = width / aspect
        }
        window.setContentSize(NSSize(width: width, height: imageAreaHeight + controlsBarHeight))

        // The clip view's bounds aren't valid until the next layout
        // pass, so defer the initial fit-to-window magnification.
        DispatchQueue.main.async { [weak self] in
            self?.fitToWindow()
        }
    }

    private func showMissingImagePlaceholder(in window: NSWindow) {
        let label = NSTextField(labelWithString: "Grandpa's map isn't included (it's the book's original artwork).\nSave pages 6-7 of Usborne's free PDF as art/Grandpa's map.png -- see README.")
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        window.contentView = label
        window.setContentSize(NSSize(width: 360, height: 120))
    }

    @objc private func zoomIn() {
        guard let scrollView else { return }
        setMagnification(scrollView.magnification * Self.zoomStep)
    }

    @objc private func zoomOut() {
        guard let scrollView else { return }
        setMagnification(scrollView.magnification / Self.zoomStep)
    }

    @objc private func zoomReset() {
        fitToWindow()
    }

    private func setMagnification(_ value: CGFloat) {
        guard let scrollView else { return }
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        let center = NSPoint(x: scrollView.documentVisibleRect.midX, y: scrollView.documentVisibleRect.midY)
        scrollView.animator().setMagnification(clamped, centeredAt: center)
    }

    /// Scales the map to exactly fill the scroll view's visible area --
    /// both the starting point when the window first opens, and what
    /// "Reset Zoom" returns to.
    private func fitToWindow() {
        guard let scrollView, mapImageSize.width > 0, mapImageSize.height > 0 else { return }
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }
        let fitScale = min(clipSize.width / mapImageSize.width, clipSize.height / mapImageSize.height)
        scrollView.minMagnification = min(0.1, fitScale * 0.5)
        scrollView.maxMagnification = max(6.0, fitScale * 6)
        scrollView.magnification = fitScale
    }

    private func positionAdjacent(_ window: NSWindow, to mainWindow: NSWindow, on screen: NSScreen) {
        let mainFrame = mainWindow.frame
        var origin = NSPoint(x: mainFrame.maxX + 12, y: mainFrame.maxY - window.frame.height)

        // If it wouldn't fit to the right on this screen, tuck it to the
        // left of the game window instead of letting it run off-screen.
        if origin.x + window.frame.width > screen.visibleFrame.maxX {
            origin.x = mainFrame.minX - window.frame.width - 12
        }
        if origin.x < screen.visibleFrame.minX {
            origin.x = screen.visibleFrame.minX
        }
        window.setFrameOrigin(origin)
    }
}

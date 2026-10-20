// The floating camera bubble. Frames come from AVCaptureVideoDataOutput; when a background
// effect is on, Vision's person segmentation cuts you out and Core Image swaps what's behind you.

import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

final class CameraBubble: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let panel: NSPanel
    private let container = DragView()
    private let imageLayer = CALayer()
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "bubble.camera", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private var configured = false
    // Read on the camera queue, written on main; only ever replaced whole.
    private var background = Settings.background
    private var pixelSize: CGFloat = Settings.bubbleSize * 2

    override init() {
        let size = Settings.bubbleSize
        panel = NSPanel(contentRect: NSRect(x: 40, y: 40, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container.wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        container.layer?.addSublayer(imageLayer)
        panel.contentView = container
        applyStyle()
        layout(size: size)
    }

    private func layout(size: CGFloat) {
        container.frame = NSRect(x: 0, y: 0, width: size, height: size)
        imageLayer.frame = container.bounds
        pixelSize = size * (panel.screen?.backingScaleFactor ?? 2)
        applyStyle()
    }

    func refreshStyle() { applyStyle() }

    /// Round bubble with a ring in the theme colour, or no frame at all in "clear" mode.
    private func applyStyle() {
        let clear = background == .clear
        let size = container.bounds.width
        container.layer?.masksToBounds = !clear
        container.layer?.cornerRadius = clear ? 0 : size / 2
        container.layer?.borderWidth = clear ? 0 : 4
        container.layer?.borderColor = Theme.nsAccent.cgColor
        container.layer?.backgroundColor = clear ? NSColor.clear.cgColor : NSColor.black.cgColor
        panel.hasShadow = !clear
    }

    func setBackground(_ bg: CameraBackground) {
        Settings.background = bg
        frameQueue.async { self.background = bg }
        background = bg
        applyStyle()
    }

    func setSize(_ size: CGFloat) {
        Settings.bubbleSize = size
        var f = panel.frame
        f.origin.y += f.height - size
        f.size = NSSize(width: size, height: size)
        panel.setFrame(f, display: true)
        layout(size: size)
    }

    func show(on screen: NSScreen?) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            log("camera access = \(ok)")
            DispatchQueue.main.async {
                guard ok else {
                    if CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("test") }) { return }  // test runs
                    return alert("Bubble needs camera access. Turn it on in System Settings → Privacy & Security → Camera.")
                }
                self.startSession()
                if let screen { self.moveOnto(screen, force: !screen.frame.intersects(self.panel.frame)) }
                self.panel.orderFrontRegardless()
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        frameQueue.async { self.session.stopRunning() }
    }

    func moveOnto(_ screen: NSScreen, force: Bool = false) {
        guard force || !screen.frame.intersects(panel.frame) else { return }
        panel.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40))
    }

    /// Keep the bubble inside the recorded region (bottom-left corner) if it isn't already.
    func keepInside(_ rect: NSRect) {
        guard panel.isVisible, !rect.contains(panel.frame) else { return }
        let size = panel.frame.width
        let inset = min(24, max(0, (rect.width - size) / 2))
        panel.setFrameOrigin(NSPoint(x: rect.minX + inset, y: rect.minY + min(24, max(0, (rect.height - size) / 2))))
    }

    private func startSession() {
        if !configured {
            configured = true
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
        frameQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    // MARK: Frame processing (camera queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var img = CIImage(cvPixelBuffer: px)

        // Centre square, mirrored like a mirror, scaled to the bubble's pixel size.
        let e = img.extent
        let side = min(e.width, e.height)
        img = img.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - side / 2), y: -(e.midY - side / 2)))
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0))
        let s = pixelSize / side
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let rect = img.extent

        let bg = background
        if bg != .off, let mask = personMask(for: img) {
            let backdrop: CIImage
            switch bg {
            case .blur: backdrop = img.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: rect)
            case .grey: backdrop = CIImage(color: CIColor(red: 0.17, green: 0.17, blue: 0.19)).cropped(to: rect)
            default: backdrop = CIImage.empty()
            }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = img
            blend.backgroundImage = backdrop
            blend.maskImage = mask
            img = blend.outputImage?.cropped(to: rect) ?? img
        }

        guard let cg = ciContext.createCGImage(img, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return }
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.contents = cg
            CATransaction.commit()
        }
    }

    private func personMask(for img: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? handler.perform([segmentation])) != nil,
              let buf = segmentation.results?.first?.pixelBuffer else { return nil }
        let m = CIImage(cvPixelBuffer: buf)
        // Scale the mask to the frame and soften its edge slightly.
        return m.transformed(by: CGAffineTransform(scaleX: img.extent.width / m.extent.width,
                                                   y: img.extent.height / m.extent.height))
            .clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: img.extent)
    }
}

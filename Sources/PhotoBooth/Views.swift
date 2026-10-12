import BoothCore
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - Live preview (layer-backed, no SwiftUI diffing per frame)

/// Shows live-view frames by setting `layer.contents` directly; aspect-fill, optionally
/// mirrored. Frames arrive from an `AsyncStream<CGImage>` consumed on the main actor.
final class LivePreviewNSView: NSView {
    private let imageLayer = CALayer()
    private var task: Task<Void, Never>?
    private(set) var frameCount = 0

    var mirrored: Bool { didSet { needsLayout = true } }

    init(mirrored: Bool) {
        self.mirrored = mirrored
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        layer = root
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        root.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        imageLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    func attach(_ frames: AsyncStream<CGImage>) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            for await frame in frames {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.imageLayer.contents = frame
                CATransaction.commit()
                self.frameCount += 1
            }
        }
    }

    func detach() { task?.cancel(); task = nil }
}

struct LivePreview: NSViewRepresentable {
    let view: LivePreviewNSView
    func makeNSView(context: Context) -> LivePreviewNSView { view }
    func updateNSView(_ nsView: LivePreviewNSView, context: Context) {}
}

// MARK: - Booth root view

struct BoothRootView: View {
    let controller: BoothController
    let preview: LivePreviewNSView
    let idlePrompt: String
    var stripMode = false
    /// Strip mode: one strip as printed (artwork or caption), drawn under the slots.
    var stripBackground: CGImage?
    /// Single-screen kiosk: the attendant's Control Panel / Quit pill (top right).
    var exitPill: KioskExitModel?

    var body: some View {
        BoothScreen(state: controller.state, banners: banners, idlePrompt: idlePrompt,
                    strip: stripMode ? StripScreen(background: stripBackground, photos: controller.stripPhotos,
                                                   message: controller.stripMessage) : nil) {
            LivePreview(view: preview)
        }
        .overlay(alignment: .topTrailing) {
            let shown = exitPill?.visible == true
            ZStack {
                if shown, let exitPill {
                    KioskExitPill(model: exitPill)
                        .padding(16)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shown)
        }
    }

    private var banners: [String] {
        var b: [String] = []
        if let s = controller.buttonStatus { b.append(s) }
        if let s = controller.inputBanner { b.append(s) }
        switch controller.state {
        case .review, .stripReview: return []
        default: return b
        }
    }
}

/// Single-screen kiosk: shown by `AppDelegate` while the pointer moves (it hides a few seconds
/// after the last movement), so the attendant can always get out with the trackpad, even when
/// PhotoBooth isn't the active app and its keyboard shortcuts go elsewhere.
@MainActor
@Observable
final class KioskExitModel {
    var visible = false
    var onControlPanel: () -> Void = {}
    var onQuit: () -> Void = {}
}

/// Small top-right pill: "Control Panel" and "Quit PhotoBooth". No confirmation: guests never
/// touch the trackpad. The hosting view accepts first mouse, so a click acts even when
/// PhotoBooth isn't the active app.
struct KioskExitPill: View {
    let model: KioskExitModel
    var body: some View {
        HStack(spacing: 6) {
            button("Control Panel", systemImage: "slider.horizontal.3", action: model.onControlPanel)
            button("Quit PhotoBooth", systemImage: "power", action: model.onQuit)
        }
        .padding(5)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// What strip mode adds to the TV: the strip column's artwork and photos so far, and the line
/// under the finished strip.
struct StripScreen {
    var background: CGImage?
    var photos: [ReviewPhoto]
    /// nil = "Printing your strip…".
    var message: String?
}

/// The TV for a given state. Without a strip it's the preview with the state's overlay on top.
/// In strip mode the strip column (full height, the strip's true shape) sits on the right and
/// the preview with its overlays fills the rest; waiting / attendant / paused and the finished
/// strip cover the whole screen. Separate from `BoothRootView` so `--render-strip-screen` can
/// draw it with a still image for the preview.
struct BoothScreen<Preview: View>: View {
    let state: BoothState
    let banners: [String]
    let idlePrompt: String
    let strip: StripScreen?
    let preview: Preview
    /// `--render-strip-screen`: draw the fly-in frozen at this progress (0–1) instead of animating.
    var flyInProgress: CGFloat?

    init(state: BoothState, banners: [String], idlePrompt: String, strip: StripScreen?, @ViewBuilder preview: () -> Preview) {
        self.state = state
        self.banners = banners
        self.idlePrompt = idlePrompt
        self.strip = strip
        self.preview = preview()
    }

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 240)
            let stripWidth = strip == nil ? 0 : PrintLayout.stripSize(height: geo.size.height).width
            let area = CGSize(width: max(0, geo.size.width - stripWidth), height: geo.size.height)
            ZStack {
                HStack(spacing: 0) {
                    ZStack {
                        Color.black
                        preview
                        if !coversScreen {
                            overlay(h: h)
                                .transition(.opacity)
                            VStack {
                                Spacer()
                                BannerStack(messages: banners, h: h)
                            }
                        }
                    }
                    .frame(width: area.width, height: area.height)
                    .clipped()
                    if let strip {
                        StripColumn(background: strip.background, photos: strip.photos, active: activeSlot, height: geo.size.height)
                    }
                }
                if coversScreen {
                    ZStack {
                        overlay(h: h)
                        VStack {
                            Spacer()
                            BannerStack(messages: banners, h: h)
                        }
                    }
                    .transition(.opacity)
                }
                if case .countdown = state {
                    // Centred on the whole screen (the camera sits above the TV's top centre), not
                    // on the preview area, which the strip column narrows.
                    LookHereView(h: h)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }
                if case let .flyIn(photo, shot, _) = state, strip != nil {
                    // From where the review showed it to its window on the strip column.
                    let from = Self.fitRect(photo.image, in: CGRect(origin: .zero, size: area))
                    let to = PrintLayout.stripWindow(shot - 1, height: geo.size.height).offsetBy(dx: area.width, dy: 0)
                    FlyInView(image: photo.image, from: from, to: to, duration: BoothSettings.stripFlyInSeconds, progress: flyInProgress)
                        .transition(.identity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.label)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// Strip mode: states that take the whole screen, strip column included.
    private var coversScreen: Bool {
        guard strip != nil else { return false }
        switch state {
        case .waitingForCamera, .attendant, .paused, .stripReview: return true
        default: return false
        }
    }

    /// The slot (1-based) of the shot under way, highlighted on the strip column.
    private var activeSlot: Int? {
        switch state {
        case let .countdown(_, shot, _), let .capturing(shot, _), let .review(_, shot, _), let .flyIn(_, shot, _): return shot
        default: return nil
        }
    }

    /// Where `ReviewView` shows the photo (aspect fit, centred).
    static func fitRect(_ image: CGImage?, in r: CGRect) -> CGRect {
        guard let image, image.width > 0, image.height > 0 else { return r }
        let s = min(r.width / CGFloat(image.width), r.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    @ViewBuilder
    private func overlay(h: CGFloat) -> some View {
        switch state {
        case .idle:
            IdlePromptView(text: idlePrompt, h: h)
        case let .countdown(remaining, shot, n):
            CountdownView(remaining: remaining, shot: shot, of: n, h: h)
        case .capturing:
            FlashView()
        case let .review(photo, shot, n):
            ReviewView(photo: photo, shot: shot, of: n, h: h)
        case let .betweenShots(next, n):
            MessageView(text: "Get ready for photo \(next) of \(n)!", h: h, dim: 0.35)
        case .flyIn:
            EmptyView()  // the photo flies over the preview (above)
        case let .stripReview(photos):
            StripReviewView(background: strip?.background, photos: photos, message: strip?.message, h: h)
        case let .notice(text):
            MessageView(text: text, h: h, dim: 0.6)
        case let .waitingForCamera(status):
            WaitingView(status: status, h: h)
        case let .attendant(issue):
            AttendantView(issue: issue, h: h)
        case .paused:
            PausedView(h: h)
        }
    }
}

// MARK: - Strip mode

/// The strip as it will print, `height` points tall: the strip artwork / caption (rendered by
/// `PrintSheet`), and each window positioned from `PrintLayout`, so it can't drift from the print.
struct StripColumn: View {
    let background: CGImage?
    let photos: [ReviewPhoto]
    /// Highlighted slot, 1-based.
    let active: Int?
    let height: CGFloat

    var body: some View {
        let size = PrintLayout.stripSize(height: height)
        ZStack {
            if let background {
                Image(decorative: background, scale: 1).resizable().interpolation(.high)
            } else {
                Color.white
            }
            ForEach(0..<PrintLayout.photosPerStrip, id: \.self) { k in
                let r = PrintLayout.stripWindow(k, height: height)
                StripSlot(number: k + 1, photo: k < photos.count ? photos[k] : nil, active: active == k + 1, h: r.height)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A window on the strip: the photo, or a soft placeholder with its number.
struct StripSlot: View {
    let number: Int
    let photo: ReviewPhoto?
    let active: Bool
    let h: CGFloat

    static let highlight = Color(red: 1, green: 0.8, blue: 0.3)

    var body: some View {
        ZStack {
            if let photo {
                // No transition: it replaces the landing fly-in photo in the same frame.
                StripPhoto(image: photo.image)
                    .transition(.identity)
            } else {
                ZStack {
                    Color(white: active ? 0.97 : 0.92)
                    Text("\(number)")
                        .font(.booth(h * 0.62, .black))
                        .foregroundStyle(active ? Self.highlight : Color(white: 0.74))
                }
                .transition(.identity)
            }
        }
        .overlay {
            if active && photo == nil {
                Rectangle()
                    .stroke(Self.highlight, lineWidth: max(2, h * 0.035))
                    .shadow(color: Self.highlight.opacity(0.7), radius: h * 0.08)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: active)
    }
}

/// A photo cropped into a window like the print: aspect fill, centred, clipped to the frame it's
/// given.
struct StripPhoto: View {
    let image: CGImage?
    var body: some View {
        Color(white: 0.35)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
    }
}

/// The reviewed photo shrinking from `from` (where the review showed it) into its window `to`,
/// cropping to the window's 3:2 as it goes.
struct FlyInView: View {
    let image: CGImage?
    let from: CGRect
    let to: CGRect
    let duration: Double
    /// Frozen at this point of the flight (dev renders); nil = animate.
    var progress: CGFloat?
    @State private var landed = false

    var body: some View {
        if let t = progress {
            FlyingPhoto(image: image, rect: Self.lerp(from, to, t))
        } else {
            FlyingPhoto(image: image, rect: landed ? to : from)
                .onAppear { withAnimation(.easeInOut(duration: duration)) { landed = true } }
        }
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

struct FlyingPhoto: View {
    let image: CGImage?
    let rect: CGRect
    var body: some View {
        StripPhoto(image: image)
            .frame(width: rect.width, height: rect.height)
            .clipped()
            .shadow(color: .black.opacity(0.5), radius: 12)
            .position(x: rect.midX, y: rect.midY)
    }
}

/// After the third photo: the whole strip, large, while it prints.
struct StripReviewView: View {
    let background: CGImage?
    let photos: [ReviewPhoto]
    let message: String?
    let h: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.1, green: 0.1, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
            VStack(spacing: h * 0.03) {
                StripColumn(background: background, photos: photos, active: nil, height: h * 0.8)
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.6), radius: h * 0.025)
                Text(message ?? "Printing your strip…")
                    .font(.booth(h * 0.045, .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, h * 0.06)
            }
        }
    }
}

private extension Font {
    static func booth(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct IdlePromptView: View {
    let text: String
    let h: CGFloat
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.booth(h * 0.085))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, h * 0.06)
                .padding(.vertical, h * 0.025)
                .background(Capsule().fill(.black.opacity(0.5)))
                .shadow(color: .black.opacity(0.6), radius: 12)
                .phaseAnimator([1.0, 1.045]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in .easeInOut(duration: 1.1) }
                .padding(.bottom, h * 0.09)
        }
    }
}

struct CountdownView: View {
    let remaining: Int
    let shot: Int
    let of: Int
    let h: CGFloat
    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            ZStack {
                Text("\(remaining)")
                    .font(.booth(h * 0.6, .black))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: h * 0.02)
                    .id(remaining)
                    .transition(.asymmetric(insertion: .scale(scale: 1.6).combined(with: .opacity),
                                            removal: .scale(scale: 0.6).combined(with: .opacity)))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: remaining)
            if of > 1 {
                // At the bottom: the top centre belongs to "Look here!".
                VStack {
                    Spacer()
                    ShotLabel(shot: shot, of: of, h: h, edge: .bottom)
                }
            }
        }
    }
}

struct ShotLabel: View {
    let shot: Int
    let of: Int
    let h: CGFloat
    var edge: Edge = .top
    var body: some View {
        Text("Photo \(shot) of \(of)")
            .font(.booth(h * 0.045, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, h * 0.03)
            .padding(.vertical, h * 0.012)
            .background(Capsule().fill(.black.opacity(0.5)))
            .padding(edge == .top ? .top : .bottom, edge == .top ? h * 0.05 : h * 0.09)
    }
}

/// During the countdown: a bouncing arrow up at the camera (above the TV's top centre), so
/// people look into the lens rather than at themselves. Never mirrored.
struct LookHereView: View {
    let h: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrow.up")
                .font(.system(size: h * 0.11, weight: .black))
            Text("Look here!")
                .font(.booth(h * 0.06, .black))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: h * 0.015)
        .phaseAnimator([0.0, 1.0]) { content, t in
            content.offset(y: -h * 0.015 * t)
        } animation: { _ in .easeInOut(duration: 0.6) }
        .padding(.top, h * 0.025)
    }
}

struct FlashView: View {
    @State private var opacity = 1.0
    var body: some View {
        Color.white
            .opacity(opacity)
            .onAppear { withAnimation(.easeOut(duration: 0.7)) { opacity = 0.0 } }
    }
}

struct ReviewView: View {
    let photo: ReviewPhoto
    let shot: Int
    let of: Int
    let h: CGFloat
    var body: some View {
        ZStack {
            Color.black
            if let img = photo.image {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("Saved!").font(.booth(h * 0.1)).foregroundStyle(.white)
            }
            if of > 1 {
                VStack {
                    ShotLabel(shot: shot, of: of, h: h)
                    Spacer()
                }
            }
        }
    }
}

struct MessageView: View {
    let text: String
    let h: CGFloat
    let dim: Double
    var body: some View {
        ZStack {
            Color.black.opacity(dim)
            Text(text)
                .font(.booth(h * 0.08))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.7), radius: 12)
                .padding(h * 0.06)
        }
    }
}

/// Shown while the attendant has paused the booth from the control panel.
struct PausedView: View {
    let h: CGFloat
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.1, green: 0.1, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
            VStack(spacing: h * 0.035) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: h * 0.12))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Back in a moment")
                    .font(.booth(h * 0.1))
                    .foregroundStyle(.white)
                Text("The photo booth is taking a short break.")
                    .font(.booth(h * 0.035, .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .multilineTextAlignment(.center)
            .padding(h * 0.06)
        }
    }
}

struct WaitingView: View {
    let status: String
    let h: CGFloat
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: h * 0.045) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .scaleEffect(max(1, h / 400))
                    .tint(.white)
                    .frame(height: h * 0.1)
                Text("Getting the camera ready…")
                    .font(.booth(h * 0.07, .bold))
                    .foregroundStyle(.white)
                Text(status)
                    .font(.booth(h * 0.03, .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(h * 0.06)
        }
    }
}

struct AttendantView: View {
    let issue: AttendantIssue
    let h: CGFloat
    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.1, blue: 0.1)
            VStack(alignment: .leading, spacing: h * 0.03) {
                Text("ATTENDANT NEEDED")
                    .font(.booth(h * 0.032, .bold))
                    .tracking(h * 0.004)
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.25))
                Text(issue.title)
                    .font(.booth(h * 0.07, .heavy))
                    .foregroundStyle(.white)
                Text(issue.detail)
                    .font(.system(size: h * 0.03, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text("When fixed, press Ctrl + Option + Command + R to retry.")
                    .font(.system(size: h * 0.025, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, h * 0.02)
            }
            .frame(maxWidth: h * 1.4, alignment: .leading)
            .padding(h * 0.08)
        }
    }
}

struct BannerStack: View {
    let messages: [String]
    let h: CGFloat
    var body: some View {
        VStack(spacing: h * 0.01) {
            ForEach(messages, id: \.self) { m in
                Text(m)
                    .font(.system(size: max(12, h * 0.022), weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, h * 0.02)
                    .padding(.vertical, h * 0.008)
                    .background(Capsule().fill(Color(red: 1, green: 0.8, blue: 0.3)))
            }
        }
        .padding(.bottom, h * 0.015)
    }
}

/// `PhotoBooth --render-strip-screen a.jpg b.jpg c.jpg --out DIR`: renders strip-mode TV frames at
/// 1920 x 1080 with the configured artwork / caption (a still photo, mirrored, stands in for the
/// live preview), plus a normal-mode countdown, and exits. No camera, nothing printed.
@MainActor
enum RenderStripScreen {
    static func run(photos: [String], outDir: String, configPath: String?) -> Int32 {
        let (config, error) = ConfigLoader.load(path: configPath)
        if let error { print("config: \(error.description) (continuing with defaults)") }
        let art = PrintSheet.loadArtwork(config.printTemplateURL)
        if let w = art.warning { print("warning: \(w)") }
        let background = PrintSheet.renderStrip(photos: [], artwork: art.image, caption: config.printCaptionText)
        let urls = photos.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let shots = urls.map { ReviewPhoto(url: $0, image: PrintSheet.loadPhoto($0, maxPixel: 1920)) }
        guard shots.allSatisfy({ $0.image != nil }) else { print("Couldn't read the photos."); return 1 }
        let dir = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let two = Array(shots.prefix(2))
        // nil photos = normal mode (no strip column).
        let frames: [(String, BoothState, [ReviewPhoto]?, CGFloat?)] = [
            ("strip-idle", .idle, [], nil),
            ("strip-screen", .countdown(remaining: 2, shot: 3, of: 3), two, nil),
            ("strip-review", .review(shots[2], shot: 3, of: 3), two, nil),
            ("strip-flyin", .flyIn(shots[2], shot: 3, of: 3), two, 0.5),
            ("strip-final", .stripReview(shots), shots, nil),
            ("strip-flash-notice", .notice(BoothController.missedFlashNotice), two, nil),
            ("countdown", .countdown(remaining: 2, shot: 1, of: 1), nil, nil),
        ]
        for (name, state, filled, progress) in frames {
            var screen = BoothScreen(state: state, banners: [], idlePrompt: config.idlePrompt,
                                     strip: filled.map { StripScreen(background: background, photos: $0, message: nil) }) {
                // Sized by its frame like the real (layer-backed) preview.
                StripPhoto(image: shots[2].image)
                    .scaleEffect(x: config.mirrorPreview ? -1 : 1, y: 1)
            }
            screen.flyInProgress = progress
            let renderer = ImageRenderer(content: screen.frame(width: 1920, height: 1080))
            renderer.scale = 1
            let url = dir.appendingPathComponent(name + ".png")
            guard let image = renderer.cgImage,
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                print("Couldn't render \(name).")
                return 1
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { print("Couldn't write \(url.path)."); return 1 }
            print("Wrote \(url.path)")
        }
        return 0
    }
}

// MARK: - Learn key

@MainActor
@Observable
final class LearnKeyModel {
    struct Entry: Identifiable {
        let id = UUID()
        let text: String
    }
    var entries: [Entry] = []
    var status = ""

    func add(_ text: String) {
        entries.insert(Entry(text: text), at: 0)
        if entries.count > 8 { entries.removeLast(entries.count - 8) }
    }
}

struct LearnKeyView: View {
    let model: LearnKeyModel
    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 300)
            ZStack(alignment: .topLeading) {
                Color.black
                VStack(alignment: .leading, spacing: h * 0.02) {
                    Text("Press your button")
                        .font(.booth(h * 0.08))
                        .foregroundStyle(.white)
                    Text("Each key press shows its HID usage, macOS key code, source device and the buttonKey value to put in config.json. Quit with Cmd+Q.")
                        .font(.system(size: h * 0.025))
                        .foregroundStyle(.white.opacity(0.7))
                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.system(size: h * 0.022, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                    }
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { i, e in
                        Text(e.text)
                            .font(.system(size: h * (i == 0 ? 0.03 : 0.022), weight: i == 0 ? .bold : .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(i == 0 ? 1 : 0.6))
                    }
                    Spacer()
                }
                .padding(h * 0.06)
            }
        }
        .ignoresSafeArea()
    }
}

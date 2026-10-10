import BoothCore
import AppKit
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

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 240)
            ZStack {
                Color.black
                LivePreview(view: preview)
                overlay(h: h)
                    .transition(.opacity)
                VStack {
                    Spacer()
                    BannerStack(messages: banners, h: h)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: controller.state.label)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var banners: [String] {
        var b: [String] = []
        if let s = controller.buttonStatus { b.append(s) }
        if let s = controller.inputBanner { b.append(s) }
        if case .review = controller.state { return [] }
        return b
    }

    @ViewBuilder
    private func overlay(h: CGFloat) -> some View {
        switch controller.state {
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
                VStack {
                    ShotLabel(shot: shot, of: of, h: h)
                    Spacer()
                }
            }
        }
    }
}

struct ShotLabel: View {
    let shot: Int
    let of: Int
    let h: CGFloat
    var body: some View {
        Text("Photo \(shot) of \(of)")
            .font(.booth(h * 0.045, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, h * 0.03)
            .padding(.vertical, h * 0.012)
            .background(Capsule().fill(.black.opacity(0.5)))
            .padding(.top, h * 0.05)
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

import AppKit
import Combine
import Network
import SwiftUI

// MARK: - Data

struct UsageWindow: Decodable {
    let utilization: Double?
    let reset_at: Int?
    let status: String?
}

struct UsageState: Decodable {
    let fetched_at: Int
    let api_source: String?
    let five_hour: UsageWindow
    let seven_day: UsageWindow
    let overage: UsageWindow
    let primary_claim: String?
    let error: String?
    let auth_expired: Bool?
    let network_wait: Bool?
}

struct FloaterConfig: Codable {
    var api_source: String
    var api_key: String?

    static let path = ("~/.claude-usage-monitor/config.json" as NSString).expandingTildeInPath

    static func load() -> FloaterConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let c = try? JSONDecoder().decode(FloaterConfig.self, from: data) else { return nil }
        return c
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: FloaterConfig.path))
    }
}

final class StateLoader: ObservableObject {
    @Published var state: UsageState?
    @Published var loadError: String?
    @Published var now: Date = Date()
    private var fileTimer: Timer?
    private var clockTimer: Timer?
    private let path = ("~/.claude-usage-monitor/state.json" as NSString).expandingTildeInPath

    init() {
        load()
        fileTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.load() }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.now = Date() }
    }

    func load() {
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            let s = try JSONDecoder().decode(UsageState.self, from: data)
            DispatchQueue.main.async {
                self.state = s
                self.loadError = nil
                self.now = Date()
            }
        } catch {
            DispatchQueue.main.async { self.loadError = "信号なし" }
        }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var minimized: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var refreshResult: RefreshResult? = nil
    @Published var showUsageHint: Bool = false

    enum RefreshResult { case success, error }

    func startRefreshAnimation() {
        isRefreshing = true
        refreshResult = nil
    }

    func endRefreshAnimation(success: Bool) {
        refreshResult = success ? .success : .error
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.isRefreshing = false
            self?.refreshResult = nil
        }
    }
}

// Map a raw monitor error string to a short label readable in the title bar.
// Full message is still shown in the body banner.
func shortErrorLabel(_ err: String) -> String {
    if err.contains("401") { return "認証失敗 401" }
    if err.contains("403") { return "拒否 403" }
    if err.contains("429") { return "制限 429" }
    if err.range(of: #"5\d\d"#, options: .regularExpression) != nil { return "サーバ異常" }
    if err.localizedCaseInsensitiveContains("timed out") || err.localizedCaseInsensitiveContains("timeout") { return "応答なし" }
    if err.localizedCaseInsensitiveContains("urlerror") || err.localizedCaseInsensitiveContains("connection") { return "接続失敗" }
    if err.localizedCaseInsensitiveContains("httperror") { return "HTTP エラー" }
    return "信号異常"
}

// MARK: - EVA palette + fonts

enum Eva {
    static let bg      = Color.black.opacity(0.78)
    static let bgDeep  = Color.black.opacity(0.92)
    static let orange  = Color(red: 1.00, green: 0.45, blue: 0.10)
    static let amber   = Color(red: 1.00, green: 0.78, blue: 0.00)
    static let green   = Color(red: 0.30, green: 0.95, blue: 0.55)
    static let red     = Color(red: 1.00, green: 0.22, blue: 0.30)
    static let magenta = Color(red: 1.00, green: 0.35, blue: 0.85)
    static let track   = Color.white.opacity(0.08)
    static let textDim = Color.white.opacity(0.50)
    static let text    = Color.white.opacity(0.95)
}

// EVA-style heavy Mincho (closest free equivalent to the show's Matisse)
func mincho(_ size: CGFloat) -> Font { Font.custom("HiraMinProN-W6", size: size) }
func minchoLight(_ size: CGFloat) -> Font { Font.custom("HiraMinProN-W3", size: size) }
func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}
// 7-segment LCD digits (DSEG7 Classic Bold, bundled in Resources/Fonts).
func lcd(_ size: CGFloat) -> Font { Font.custom("DSEG7Classic-Bold", size: size) }

func severity(_ util: Double) -> Color {
    switch util {
    case ..<0.5: return Eva.green
    case ..<0.8: return Eva.amber
    default:     return Eva.orange
    }
}

func fmtRemaining(_ resetAt: Int?, now: Date) -> String {
    guard let r = resetAt else { return "--" }
    let secs = max(0, r - Int(now.timeIntervalSince1970))
    let h = secs / 3600
    let m = (secs % 3600) / 60
    if h > 0 { return String(format: "%dH %02dM", h, m) }
    return String(format: "%dM", m)
}

func fmtClock(_ resetAt: Int?, now: Date) -> String {
    guard let r = resetAt else { return "--:--" }
    let secs = max(0, r - Int(now.timeIntervalSince1970))
    let h = secs / 3600
    let m = (secs % 3600) / 60
    return String(format: "%d:%02d", h, m)
}

// MARK: - EVA frame shapes

// Octagonal EVA-instrument frame. Each side's cut can be toggled; default = all four cut.
struct EvaPanel: Shape {
    var cut: CGFloat = 12
    var cutLeft: Bool = true
    var cutRight: Bool = true
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let lc = cutLeft ? cut : 0
        let rc = cutRight ? cut : 0
        p.move(to: CGPoint(x: rect.minX + lc, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - rc, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rc))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rc))
        p.addLine(to: CGPoint(x: rect.maxX - rc, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + lc, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - lc))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + lc))
        p.closeSubpath()
        return p
    }
}

// Solid red triangle that sits in a cut-away corner. Doubles as a click target
// (the bottom-right one is wired up as a minimize hot zone).
struct HazardCorner: View {
    var size: CGFloat
    var rotated: Bool = false  // true = bottom-right corner
    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let tri = Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.closeSubpath()
            }
            ctx.fill(tri, with: .color(Eva.red))
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotated ? 180 : 0))
    }
}

// Horizontal yellow+black hazard banner — fits across an edge.
struct HazardStripes: View {
    var height: CGFloat = 6
    var body: some View {
        Canvas { ctx, size in
            let stripeW: CGFloat = 9
            let slant = size.height
            var x: CGFloat = -slant
            var i = 0
            while x < size.width + slant {
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + stripeW, y: 0))
                    p.addLine(to: CGPoint(x: x + stripeW + slant, y: size.height))
                    p.addLine(to: CGPoint(x: x + slant, y: size.height))
                    p.closeSubpath()
                }
                ctx.fill(path, with: .color(i % 2 == 0 ? Color.black : Eva.amber))
                x += stripeW
                i += 1
            }
        }
        .frame(height: height)
    }
}

// EVA-style red diagonal warning stripes — chunky red diagonals on transparent gaps.
struct RedDiagonalStripes: View {
    var stripeWidth: CGFloat = 7
    var gap: CGFloat = 5
    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let step = stripeWidth + gap
            var x: CGFloat = -h
            while x < size.width + h {
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + stripeWidth, y: 0))
                    p.addLine(to: CGPoint(x: x + stripeWidth + h, y: h))
                    p.addLine(to: CGPoint(x: x + h, y: h))
                    p.closeSubpath()
                }
                ctx.fill(path, with: .color(Eva.red))
                x += step
            }
        }
    }
}

// Vertical bar of red+black diagonal hazard stripes — the iconic EVA NERV side strip.
struct HazardStripeBar: View {
    var stripe: CGFloat = 4
    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            var x: CGFloat = -h
            var i = 0
            while x < w + h {
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + stripe, y: 0))
                    p.addLine(to: CGPoint(x: x + stripe + h, y: h))
                    p.addLine(to: CGPoint(x: x + h, y: h))
                    p.closeSubpath()
                }
                ctx.fill(path, with: .color(i % 2 == 0 ? Color.black : Eva.red))
                x += stripe
                i += 1
            }
        }
    }
}

// MARK: - MAX form

struct MetricRow: View {
    let label: String
    let subtitle: String
    let util: Double
    let resetAt: Int?
    let now: Date
    let hasError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(subtitle)
                    .font(mincho(13))
                    .foregroundStyle(Color(white: 0.30))
                    .tracking(1)
                    .fixedSize()
                Spacer(minLength: 4)
                Text(fmtRemaining(resetAt, now: now))
                    .font(lcd(10))
                    .foregroundStyle(Color(white: 0.5))
                    .fixedSize()
                Text(hasError ? "  Err" : String(format: "%05.1f%%", util * 100))
                    .font(lcd(13))
                    .foregroundStyle(hasError ? Eva.red : severity(util))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                    .fixedSize()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.20))
                    Rectangle()
                        .fill(severity(util))
                        .frame(width: max(0, min(1, util)) * g.size.width)
                }
                .overlay(
                    GeometryReader { gg in
                        ForEach(1..<10, id: \.self) { i in
                            Rectangle()
                                .fill(Color.white.opacity(0.55))
                                .frame(width: 1)
                                .position(x: gg.size.width * Double(i) / 10, y: gg.size.height / 2)
                        }
                    }
                )
                .overlay(Rectangle().stroke(Color(white: 0.75).opacity(0.55), lineWidth: 1))
            }
            .frame(height: 8)
        }
    }
}

// Compact one-line summary of the underlying error string.
// "HTTPError: HTTP Error 401: Unauthorized" -> "HTTP 401 Unauthorized"
func compactError(_ err: String) -> String {
    var s = err.replacingOccurrences(of: "HTTPError: ", with: "")
    s = s.replacingOccurrences(of: "HTTP Error ", with: "HTTP ")
    s = s.replacingOccurrences(of: ": ", with: " ")
    return s
}

// Actionable hint based on the error category.
// One-line short description + zero-or-more CLI commands.
// Commands are rendered as monospace amber-on-black chips so the user can
// recognise them as something to type into a terminal.
struct ErrorAdvice {
    let explanation: String
    let commands: [String]
}

func errorAdvice(_ err: String, authExpired: Bool = false) -> ErrorAdvice {
    if err.contains("401") || authExpired {
        return ErrorAdvice(
            explanation: "認証の有効期限切れ。ボタンでログイン画面へ。復旧しない場合はターミナルで:",
            commands: ["claude auth login"]
        )
    }
    if err.contains("403") {
        return ErrorAdvice(
            explanation: "claude.ai でサブスク状態を確認",
            commands: []
        )
    }
    if err.contains("429") {
        return ErrorAdvice(
            explanation: "10〜15 分後に右上の「新」を押す",
            commands: []
        )
    }
    if err.range(of: #"5\d\d"#, options: .regularExpression) != nil {
        return ErrorAdvice(
            explanation: "Anthropic 側で障害発生中。後で再試行",
            commands: []
        )
    }
    if err.localizedCaseInsensitiveContains("timeout") {
        return ErrorAdvice(
            explanation: "応答なし。ネット接続を確認",
            commands: []
        )
    }
    if err.localizedCaseInsensitiveContains("urlerror") || err.localizedCaseInsensitiveContains("connection") {
        return ErrorAdvice(
            explanation: "ネット接続を確認 (Wi-Fi / VPN / プロキシ)",
            commands: []
        )
    }
    return ErrorAdvice(
        explanation: "右上の「新」を押して再試行",
        commands: []
    )
}

// Single banner that replaces the 3 metric rows when the monitor reports an error.
// Centered vertically in the body so whitespace is balanced rather than dumped at the bottom.
struct ErrorBanner: View {
    let error: String
    let authExpired: Bool
    var onReLogin: (() -> Void)?

    var body: some View {
        let advice = errorAdvice(error, authExpired: authExpired)
        let showReLogin = authExpired || error.contains("401")
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Eva.red)
                    .frame(width: 10, height: 10)
                Text(shortErrorLabel(error))
                    .font(.custom("HiraMinProN-W6", size: 15).weight(.heavy))
                    .foregroundStyle(Eva.red)
                    .fixedSize()
            }
            Text(compactError(error))
                .font(mono(10, .regular))
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(advice.explanation)
                .font(.custom("HiraMinProN-W6", size: 11))
                .foregroundStyle(Color(white: 0.20))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            ForEach(advice.commands, id: \.self) { cmd in
                Text(cmd)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Eva.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.85))
                    .fixedSize()
            }
            if showReLogin {
                ReLoginButton(onReLogin: onReLogin)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct ReLoginButton: View {
    var onReLogin: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Text("ログイン画面へ")
            .font(.custom("HiraMinProN-W6", size: 12))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(isHovering ? Eva.green : Eva.amber)
            .clipShape(EvaPanel(cut: 4))
            .overlay(EvaPanel(cut: 4).stroke(Color.white.opacity(0.3), lineWidth: 1))
            .onHover { isHovering = $0 }
    }
}

// Shown while the monitor is waiting for the network to come back (typical for
// a few seconds right after the machine wakes). Calm amber pulse, NOT a red
// error — nothing is wrong, the connection just isn't up yet.
struct NetworkWaitBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let v = 0.3 + 0.5 * (1 + sin(t * .pi * 2 / 1.6)) / 2
                    Rectangle()
                        .fill(Eva.amber.opacity(v))
                        .frame(width: 10, height: 10)
                }
                Text("ネット復帰待ち")
                    .font(.custom("HiraMinProN-W6", size: 15).weight(.heavy))
                    .foregroundStyle(Eva.amber)
                    .fixedSize()
            }
            Text("接続が戻り次第、自動で再取得します")
                .font(.custom("HiraMinProN-W6", size: 11))
                .foregroundStyle(Color(white: 0.30))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MaxView: View {
    @ObservedObject var loader: StateLoader
    @ObservedObject var model: AppModel

    // Broken into computed sub-views: the full body was one expression large
    // enough to trip "unable to type-check in reasonable time" on the CI Swift
    // toolchain. Smaller chunks type-check independently.
    private var isReceiving: Bool { model.isRefreshing && model.refreshResult == nil }

    @ViewBuilder private var statusIndicator: some View {
        if let s = loader.state {
            if isReceiving {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let v = 0.45 + 0.45 * sin(t * .pi * 2 / 1.4)
                    Text("受信中")
                        .font(mincho(10))
                        .foregroundStyle(Eva.amber.opacity(v))
                }
                .fixedSize()
            } else {
                let age = max(0, Int(loader.now.timeIntervalSince1970) - s.fetched_at)
                let stale = s.error != nil
                HStack(spacing: 2) {
                    Text("\(age)")
                        .font(lcd(10))
                        .foregroundStyle((stale ? Eva.red : Color.white).opacity(0.7))
                        .fixedSize()
                    Text("秒前")
                        .font(mincho(10))
                        .foregroundStyle((stale ? Eva.red : Color.white).opacity(0.7))
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var refreshButton: some View {
        ZStack {
            if isReceiving {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let v = 0.12 + 0.76 * pow((1 + sin(t * .pi * 2 / 1.4)) / 2, 1.8)
                    Rectangle().fill(Eva.amber.opacity(v))
                }
                .frame(width: 14, height: 14)
            } else if let r = model.refreshResult {
                Rectangle()
                    .fill(r == .success ? Eva.green : Eva.red)
                    .frame(width: 14, height: 14)
            }
            Rectangle()
                .stroke(Color.white.opacity(0.85), lineWidth: 1)
                .frame(width: 14, height: 14)
            Text("新")
                .font(.custom("HiraMinProN-W6", size: 10))
                .foregroundStyle(model.isRefreshing ? Color.black.opacity(0.8) : Color.white.opacity(0.85))
        }
        .frame(width: 14, height: 14)
    }

    // 最小化按钮：白色细线方框内嵌一根短横，比黄色三角更克制、更仪表化
    private var minimizeButton: some View {
        ZStack {
            Rectangle()
                .stroke(Color.white.opacity(0.85), lineWidth: 1)
                .frame(width: 14, height: 14)
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 8, height: 1.5)
        }
        .frame(width: 14, height: 14)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text("クロード稼働率")
                .font(.custom("HiraMinProN-W6", size: 15).weight(.black))
                .foregroundStyle(.white)
                .tracking(2)
                .fixedSize()
            Spacer(minLength: 6)
            statusIndicator
            refreshButton
            minimizeButton
        }
        // Lock the title row to exactly the gradient bar's height so the title
        // text always lands inside the gradient regardless of how tall (or
        // short) the body content is below it.
        .frame(height: 30)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var contentArea: some View {
        VStack(spacing: 8) {
            if let s = loader.state {
                if s.network_wait == true {
                    NetworkWaitBanner()
                } else if let err = s.error {
                    ErrorBanner(error: err, authExpired: s.auth_expired == true, onReLogin: {
                        NSWorkspace.shared.open(URL(string: "https://claude.ai/login")!)
                    })
                } else {
                    MetricRow(label: "5H",  subtitle: "活動限界", util: s.five_hour.utilization ?? 0, resetAt: s.five_hour.reset_at, now: loader.now, hasError: false)
                    MetricRow(label: "7D",  subtitle: "週間限界", util: s.seven_day.utilization ?? 0, resetAt: s.seven_day.reset_at, now: loader.now, hasError: false)
                    MetricRow(label: "OVR", subtitle: "暴走",     util: s.overage.utilization   ?? 0, resetAt: s.overage.reset_at,   now: loader.now, hasError: false)
                }
            } else {
                Text(loader.loadError ?? "同期中…")
                    .font(mincho(12))
                    .foregroundStyle(Color(white: 0.5))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            contentArea
        }
        .padding(EdgeInsets(top: 10, leading: 32, bottom: 4, trailing: 18))
        .frame(width: 290, height: 178)
        .background(
            // 顶部横向渐变（粉→紫→深蓝），与左侧渐变同色同强度，
            // 视觉上作为侧条向右的延续。放在 .background 而非 .overlay，
            // 这样渐变在文字之下、material 之上，不会挡住标题。
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.20, blue: 0.55),
                    Color(red: 0.45, green: 0.10, blue: 0.85),
                    Color(red: 0.10, green: 0.10, blue: 0.55)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 30)
            .opacity(0.78)
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        )
        .background(
            EvaPanel(cut: 14)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
        )
        .overlay(
            EvaPanel(cut: 14)
                .fill(Color.white.opacity(0.03))
                .allowsHitTesting(false)
        )
        .overlay(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.20, blue: 0.55),
                    Color(red: 0.45, green: 0.10, blue: 0.85),
                    Color(red: 0.10, green: 0.10, blue: 0.55)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: 14)
            .opacity(0.78)
            .allowsHitTesting(false),
            alignment: .leading
        )
        .overlay(
            RedDiagonalStripes()
                .frame(height: 10)
                .allowsHitTesting(false),
            alignment: .top
        )
        .clipShape(EvaPanel(cut: 14))
        .overlay(EvaPanel(cut: 14).stroke(Color.white.opacity(0.5), lineWidth: 1))
        .overlay(HazardCorner(size: 14, rotated: true),  alignment: .bottomTrailing)
        .overlay(
            Group {
                if model.showUsageHint {
                    Text("▸ 公式で使用量を確認")
                        .font(mincho(9))
                        .foregroundStyle(Eva.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.88))
                        .clipShape(EvaPanel(cut: 4))
                        .overlay(EvaPanel(cut: 4).stroke(Eva.amber.opacity(0.4), lineWidth: 1))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: model.showUsageHint)
            .padding(.top, 44).padding(.leading, 32),
            alignment: .topLeading
        )
    }
}

// MARK: - MIN form (EVA umbilical countdown)

struct MinView: View {
    @ObservedObject var loader: StateLoader
    @ObservedObject var model: AppModel

    var body: some View {
        let networkWait = loader.state?.network_wait == true
        let hasError = loader.state?.error != nil
        let util = loader.state?.five_hour.utilization ?? 0
        let remaining = max(0, min(100, Int((1 - util) * 100 + 0.5)))
        let errTag: String = {
            guard let err = loader.state?.error else { return "Err" }
            if loader.state?.auth_expired == true || err.contains("401") { return "認証" }
            if err.localizedCaseInsensitiveContains("timeout") || err.localizedCaseInsensitiveContains("urlerror") || err.localizedCaseInsensitiveContains("connection") { return "接続" }
            if err.range(of: #"5\d\d"#, options: .regularExpression) != nil { return "障害" }
            return "Err"
        }()
        // tag color: amber while merely waiting for the network, red for real errors
        let statusTag = networkWait ? "待機" : errTag
        let abnormal = networkWait || hasError
        let tagColor = networkWait ? Eva.amber : Eva.red
        return HStack(spacing: 4) {
            Text("理論限界")
                .font(mincho(13))
                .foregroundStyle(Eva.amber)
                .tracking(1)
                .fixedSize()
            Spacer(minLength: 2)
            Text(abnormal ? statusTag : String(format: "%03d", remaining))
                .font(abnormal ? mincho(13) : lcd(13))
                .foregroundStyle(abnormal ? tagColor : severity(util))
                .fixedSize()
        }
        .padding(EdgeInsets(top: 4, leading: 17, bottom: 4, trailing: 8))
        .frame(width: 116, height: 28)
        .background(
            EvaPanel(cut: 6, cutLeft: false)
                .fill(.ultraThinMaterial)
                .opacity(0.45)
        )
        .overlay(
            HazardStripeBar(stripe: 2.5)
                .frame(width: 8)
                .allowsHitTesting(false),
            alignment: .leading
        )
        .clipShape(EvaPanel(cut: 6, cutLeft: false))
        .overlay(EvaPanel(cut: 6, cutLeft: false).stroke(Color.white.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var loader: StateLoader
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.minimized {
                MinView(loader: loader, model: model)
            } else {
                MaxView(loader: loader, model: model)
            }
        }
    }
}

// MARK: - Menu bar icon (black-and-white CC circle, template adapts to light/dark)

func makeMenuIcon() -> NSImage {
    let size: CGFloat = 18
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let inset: CGFloat = 1
    let circleRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let circle = NSBezierPath(ovalIn: circleRect)
    circle.lineWidth = 1.3
    NSColor.black.setStroke()
    circle.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .heavy),
        .foregroundColor: NSColor.black,
    ]
    let str = "CC" as NSString
    let strSize = str.size(withAttributes: attrs)
    str.draw(
        at: NSPoint(x: (size - strSize.width) / 2, y: (size - strSize.height) / 2 - 0.5),
        withAttributes: attrs
    )

    img.unlockFocus()
    img.isTemplate = true
    return img
}

// MARK: - App

// NSPanel that accepts first-mouse clicks and can become key — fixes the
// "first click moves window, second click triggers button" bug.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }
    // Constrain to the screen's visible area (below menu bar, above dock).
    // The user can push right up to the edges, but the panel never overlaps them.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let visible = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame ?? frameRect
        var f = frameRect
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        return f
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Container view whose hit-test forcibly returns the input view, bypassing
// any z-order or hit-testing weirdness from the SwiftUI host underneath.
final class InputContainer: NSView {
    weak var input: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { input ?? super.hitTest(point) }
}

// Single NSView that sits on top of the SwiftUI host and owns ALL mouse input.
// Decides: click vs drag (by movement threshold), and which action to fire
// (toggle min, expand max) based on click location and model state.
final class PanelInputView: NSView {
    weak var model: AppModel?
    var toggleHotZones: [NSRect] = []
    var refreshHotZones: [NSRect] = []
    var usageHotZones: [NSRect] = []
    var reLoginHotZones: [NSRect] = []
    var onRefresh: (() -> Void)?
    var onUsage: (() -> Void)?
    var onReLogin: (() -> Void)?

    private var initialMouse: NSPoint?
    private var initialOrigin: NSPoint?
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !(model?.minimized ?? true) else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let over = usageHotZones.contains(where: { $0.contains(loc) })
        if model?.showUsageHint != over { model?.showUsageHint = over }
    }

    override func mouseExited(with event: NSEvent) {
        model?.showUsageHint = false
    }

    override func mouseDown(with event: NSEvent) {
        initialMouse = NSEvent.mouseLocation
        initialOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m = initialMouse, let o = initialOrigin, let w = window else { return }
        let cur = NSEvent.mouseLocation
        let dx = cur.x - m.x
        let dy = cur.y - m.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        if didDrag {
            w.setFrameOrigin(NSPoint(x: o.x + dx, y: o.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dragged = didDrag
        let mini = model?.minimized ?? false
        let inHot = toggleHotZones.contains(where: { $0.contains(loc) })
        let inRefresh = refreshHotZones.contains(where: { $0.contains(loc) })
        let inUsage = usageHotZones.contains(where: { $0.contains(loc) })
        let inReLogin = reLoginHotZones.contains(where: { $0.contains(loc) })
        NSLog("[floater] mouseUp loc=(%.1f,%.1f) dragged=%d mini=%d inHot=%d inRefresh=%d inUsage=%d inReLogin=%d",
              loc.x, loc.y, dragged, mini, inHot, inRefresh, inUsage, inReLogin)
        defer {
            initialMouse = nil
            initialOrigin = nil
            didDrag = false
        }
        if dragged { return }
        guard let model else { return }
        if mini {
            model.minimized = false
            return
        }
        if inReLogin { onReLogin?(); return }
        if inRefresh { onRefresh?(); return }
        if inUsage { onUsage?(); return }
        if inHot { model.minimized = true }
    }
}

// Real NSButton — guaranteed to handle first-mouse correctly inside a
// .nonactivatingPanel and never to trigger background window drag.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

// Visible icon button (the ▼).
struct IconButton: NSViewRepresentable {
    let symbol: String
    let color: NSColor
    let action: () -> Void

    final class Coord: NSObject {
        var action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func clicked() { action() }
    }
    func makeCoordinator() -> Coord { Coord(action) }

    func makeNSView(context: Context) -> FirstMouseButton {
        let btn = FirstMouseButton()
        btn.title = ""
        btn.isBordered = false
        btn.bezelStyle = .smallSquare
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            btn.image = img
            btn.imagePosition = .imageOnly
            btn.imageScaling = .scaleProportionallyDown
        }
        btn.contentTintColor = color
        btn.target = context.coordinator
        btn.action = #selector(Coord.clicked)
        return btn
    }
    func updateNSView(_ btn: FirstMouseButton, context: Context) {
        context.coordinator.action = action
    }
}

// Custom NSView that distinguishes a click from a drag:
//   - mouse-up with no movement (≤ 3pt) → fires `onClick`
//   - any meaningful movement → manually moves the window (so MIN stays draggable)
final class ClickOrDragView: NSView {
    var onClick: (() -> Void)?
    private var initialMouse: NSPoint?
    private var initialOrigin: NSPoint?
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        initialMouse = NSEvent.mouseLocation
        initialOrigin = window?.frame.origin
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let m = initialMouse, let o = initialOrigin, let w = window else { return }
        let cur = NSEvent.mouseLocation
        let dx = cur.x - m.x
        let dy = cur.y - m.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        if didDrag {
            w.setFrameOrigin(NSPoint(x: o.x + dx, y: o.y + dy))
        }
    }
    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
        initialMouse = nil
        initialOrigin = nil
        didDrag = false
    }
}

struct ClickOrDragHandler: NSViewRepresentable {
    let onClick: () -> Void
    func makeNSView(context: Context) -> ClickOrDragView {
        let v = ClickOrDragView()
        v.onClick = onClick
        return v
    }
    func updateNSView(_ v: ClickOrDragView, context: Context) {
        v.onClick = onClick
    }
}

// Invisible NSButton overlay — turns any SwiftUI region into a real click target.
struct InvisibleButton: NSViewRepresentable {
    let action: () -> Void

    final class Coord: NSObject {
        var action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func clicked() { action() }
    }
    func makeCoordinator() -> Coord { Coord(action) }

    func makeNSView(context: Context) -> FirstMouseButton {
        let btn = FirstMouseButton()
        btn.title = ""
        btn.isBordered = false
        btn.isTransparent = true
        btn.bezelStyle = .smallSquare
        btn.target = context.coordinator
        btn.action = #selector(Coord.clicked)
        return btn
    }
    func updateNSView(_ btn: FirstMouseButton, context: Context) {
        context.coordinator.action = action
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var apiSource = "claude_oauth"
    @State private var apiKey = ""
    @State private var status = ""
    var onSave: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API 設定")
                .font(.custom("HiraMinProN-W6", size: 18))

            Picker("API ソース", selection: $apiSource) {
                Text("Claude (OAuth — Claude Code 連携)").tag("claude_oauth")
                Text("Claude (API Key)").tag("claude_apikey")
            }
            .pickerStyle(.radioGroup)

            if apiSource != "claude_oauth" {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            if apiSource == "claude_oauth" {
                Text("Claude Code CLI のキーチェーン認証を使用します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("エラー") ? .red : .green)
                }
                Spacer()
                Button("保存") { save() }
                    .disabled(apiSource != "claude_oauth" && apiKey.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { loadConfig() }
    }

    private func loadConfig() {
        guard let c = FloaterConfig.load() else { return }
        apiSource = c.api_source
        apiKey = c.api_key ?? ""
    }

    private func save() {
        var c = FloaterConfig(api_source: apiSource)
        if apiSource != "claude_oauth" { c.api_key = apiKey }
        do {
            try c.save()
            status = "保存しました"
            onSave?()
        } catch {
            status = "エラー: \(error.localizedDescription)"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var inputView: PanelInputView!
    var settingsWindow: NSWindow?
    let loader = StateLoader()
    let model = AppModel.shared
    var cancellable: AnyCancellable?
    var refreshPollTimer: Timer?
    var pathMonitor: NWPathMonitor?
    var toggleVisibilityItem: NSMenuItem?

    let maxSize = NSSize(width: 290, height: 178)
    let minSize = NSSize(width: 116, height: 28)

    // Hot zones for "minimize" while in MAX form: top-right ▢ + bottom-right red corner.
    // After the title-bar realignment, the ▢ visible at x≈258–272, so we tighten
    // the hot zone to x=254–290 to avoid swallowing 「新」 button clicks (新 ends at x=250).
    static func maxHotZones(for size: NSSize) -> [NSRect] {
        return [
            NSRect(x: size.width - 36, y: size.height - 50, width: 36, height: 44),  // top-right ▢
            NSRect(x: size.width - 36, y: 0, width: 36, height: 32),                 // bottom-right ▼
        ]
    }

    // Hot zone for "force refresh" while in MAX form: covers the "X秒前" age
    // text and the 「新」 button (sitting between age and minimize). Must end
    // before the toggle hot zone (x=254) to keep them disjoint.
    static func maxRefreshHotZones(for size: NSSize) -> [NSRect] {
        return [
            NSRect(x: size.width - 130, y: size.height - 50, width: 90, height: 44),
        ]
    }

    static func maxUsageHotZones(for size: NSSize) -> [NSRect] {
        return [
            NSRect(x: 0, y: size.height - 50, width: size.width - 130, height: 50),
        ]
    }

    static func maxReLoginHotZones(for size: NSSize) -> [NSRect] {
        return [
            NSRect(x: 32, y: 8, width: 140, height: 28),
        ]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: RootView(loader: loader, model: model))
        host.autoresizingMask = [.width, .height]

        let inputView = PanelInputView()
        inputView.autoresizingMask = [.width, .height]
        inputView.model = model
        self.inputView = inputView

        let container = InputContainer(frame: NSRect(origin: .zero, size: maxSize))
        container.autoresizingMask = [.width, .height]
        container.input = inputView
        host.frame = container.bounds
        container.addSubview(host)
        inputView.frame = container.bounds
        container.addSubview(inputView)  // on top — receives all clicks

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(x: screen.maxX - maxSize.width - 20, y: screen.maxY - maxSize.height - 20)

        let p = FloatingPanel(
            contentRect: NSRect(origin: origin, size: maxSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.isMovableByWindowBackground = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = container
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.makeKeyAndOrderFront(nil)
        self.panel = p

        inputView.toggleHotZones = AppDelegate.maxHotZones(for: maxSize)
        inputView.refreshHotZones = AppDelegate.maxRefreshHotZones(for: maxSize)
        inputView.usageHotZones = AppDelegate.maxUsageHotZones(for: maxSize)
        inputView.reLoginHotZones = AppDelegate.maxReLoginHotZones(for: maxSize)
        inputView.onRefresh = { [weak self] in self?.forceRefresh() }
        inputView.onUsage = { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
        inputView.onReLogin = { [weak self] in self?.handleReLogin() }

        cancellable = model.$minimized.sink { [weak self] mini in
            guard let self else { return }
            // Defer the panel resize one runloop so SwiftUI renders the new view
            // (Min/Max) FIRST — otherwise we briefly see the old view clipped
            // inside the new panel size (the "square with cut text" glitch).
            DispatchQueue.main.async {
                let target = mini ? self.minSize : self.maxSize
                let cur = self.panel.frame
                var newOrigin: NSPoint
                if mini {
                    // MAX → MIN: anchor MIN's top-right to MAX's top-right
                    // (i.e. MIN appears at the ▼ corner, growing inward).
                    newOrigin = NSPoint(x: cur.maxX - target.width,
                                        y: cur.maxY - target.height)
                } else {
                    // MIN → MAX: by default anchor MAX's top-right to MIN's top-right
                    // (MAX grows down-and-left from MIN). If that would push MAX
                    // past the screen's left edge, flip and grow right from MIN's
                    // left edge instead.
                    let screen = self.panel.screen?.visibleFrame
                        ?? NSScreen.main?.visibleFrame
                        ?? .zero
                    var x = cur.maxX - target.width
                    let y = cur.maxY - target.height
                    if x < screen.minX {
                        x = cur.minX
                    }
                    newOrigin = NSPoint(x: x, y: y)
                }
                self.panel.setFrame(NSRect(origin: newOrigin, size: target), display: true, animate: false)
                if !mini {
                    self.inputView.toggleHotZones = AppDelegate.maxHotZones(for: target)
                    self.inputView.refreshHotZones = AppDelegate.maxRefreshHotZones(for: target)
                    self.inputView.usageHotZones = AppDelegate.maxUsageHotZones(for: target)
                    self.inputView.reLoginHotZones = AppDelegate.maxReLoginHotZones(for: target)
                } else {
                    self.inputView.refreshHotZones = []
                    self.inputView.usageHotZones = []
                    self.inputView.reLoginHotZones = []
                    self.model.showUsageHint = false
                }
            }
        }

        setupMenuBar()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.forceRefresh()
        }

        let monitor = NWPathMonitor()
        var networkWasDown = false
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied && networkWasDown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.forceRefresh() }
            }
            networkWasDown = (path.status != .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "net-watch"))
        self.pathMonitor = monitor

        if FloaterConfig.load() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showSettings()
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = makeMenuIcon()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "今すぐ更新",   action: #selector(forceRefresh),     keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "形態切替",     action: #selector(toggleForm),       keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "位置リセット", action: #selector(resetPosition),    keyEquivalent: ""))
        let toggleItem = NSMenuItem(title: "フローターを隠す", action: #selector(toggleVisibility), keyEquivalent: "h")
        self.toggleVisibilityItem = toggleItem
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem(title: "使用状況 (claude.ai)", action: #selector(openUsagePage), keyEquivalent: "u"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "設定",         action: #selector(showSettings),     keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc func refresh() { loader.load() }
    @objc func forceRefresh() {
        guard !model.isRefreshing else { return }
        let startFetchedAt = loader.state?.fetched_at ?? 0
        let animStart = Date()
        model.startRefreshAnimation()
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        let monitorPath = ("~/.claude-usage-monitor/bin/monitor.py" as NSString).expandingTildeInPath
        task.arguments = ["-USR1", "-f", monitorPath]
        try? task.run()
        var pollCount = 0
        let statePath = ("~/.claude-usage-monitor/state.json" as NSString).expandingTildeInPath
        refreshPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.loader.load()
            pollCount += 1
            if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
               let s = try? JSONDecoder().decode(UsageState.self, from: data),
               s.fetched_at != startFetchedAt {
                timer.invalidate()
                self.refreshPollTimer = nil
                let success = s.error == nil && s.network_wait != true
                let delay = max(0, 1.5 - Date().timeIntervalSince(animStart))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.model.endRefreshAnimation(success: success)
                }
            } else if pollCount >= 15 {
                timer.invalidate()
                self.refreshPollTimer = nil
                self.model.endRefreshAnimation(success: false)
            }
        }
    }
    func handleReLogin() {
        // Open the Claude login page in the browser as a reminder/jump-off. Note
        // this alone does NOT refresh the local keychain token the monitor reads
        // — the banner's `claude auth login` hint is the command that truly does.
        NSWorkspace.shared.open(URL(string: "https://claude.ai/login")!)
        // Re-probe shortly after, in case the user fixes auth out-of-band.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.forceRefresh()
        }
    }
    @objc func toggleForm() { model.minimized.toggle() }
    @objc func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }
    @objc func resetPosition() {
        let f = NSScreen.main?.visibleFrame ?? .zero
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.maxX - s.width - 20, y: f.maxY - s.height - 20))
    }
    @objc func toggleVisibility() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    @objc func showSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView { [weak self] in self?.restartMonitor() }
        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "ClaudeFloater 設定"
        w.contentView = hosting
        w.center()
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
    }

    func restartMonitor() {
        let monitorPath = ("~/.claude-usage-monitor/bin/monitor.py" as NSString).expandingTildeInPath
        let kill = Process()
        kill.launchPath = "/usr/bin/pkill"
        kill.arguments = ["-f", monitorPath]
        try? kill.run()
        kill.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let start = Process()
            start.launchPath = "/usr/bin/python3"
            start.arguments = [monitorPath]
            start.standardOutput = FileHandle.nullDevice
            start.standardError = FileHandle.nullDevice
            try? start.run()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.loader.load()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        toggleVisibilityItem?.title = panel.isVisible ? "フローターを隠す" : "フローターを表示"
    }
}

// Single-instance guard (only meaningful when launched from .app bundle)
if let bid = Bundle.main.bundleIdentifier, !bid.isEmpty {
    let mine = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .filter { $0.processIdentifier != mine }
    if !others.isEmpty {
        others.first?.activate(options: [])
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

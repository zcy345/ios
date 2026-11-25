import SwiftUI

/// 配色和图标的渐变一致（#7B5CFF → #4C7DFF → #12D3EE），深色界面，和 Android 版一样
enum Theme {
    static let c1 = Color(hex: 0x7B5CFF)
    static let c2 = Color(hex: 0x4C7DFF)
    static let c3 = Color(hex: 0x12D3EE)
    static let accent = Color(hex: 0x5B7CFF)
    static let good = Color(hex: 0x35D49A)
    static let warn = Color(hex: 0xF5B84A)
    static let bad = Color(hex: 0xFF5D6C)
    static let bg = Color(hex: 0x0B0D14)
    static let card = Color(hex: 0x151925)
    static let cardHi = Color(hex: 0x1D2231)
    static let stroke = Color.white.opacity(0.07)
    static let text = Color(hex: 0xE9ECF5)
    static let sub = Color(hex: 0xA9B0C3)
    static let faint = Color(hex: 0x6B7389)

    static let gradient = LinearGradient(colors: [c1, c2, c3], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let softGradient = LinearGradient(colors: [c1.opacity(0.28), c2.opacity(0.18), c3.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

/// 圆角卡片
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.sub).textCase(nil)
            .padding(.horizontal, 4)
    }
}

/// 渐变的主按钮
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.gradient.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// 状态小圆点 + 文字
struct StatusPill: View {
    let color: Color
    let text: String
    var spinning = false

    var body: some View {
        HStack(spacing: 6) {
            if spinning {
                ProgressView().controlSize(.mini).tint(color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.8), radius: 4)
            }
            Text(text).font(.caption.weight(.medium)).foregroundStyle(Theme.sub).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke))
    }
}

/// 设备图标（系统类型）
struct DeviceIcon: View {
    let os: OsKind
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.softGradient)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).stroke(Color.white.opacity(0.08))
            Image(systemName: os.symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// 底部弹出的提示条（可以带一个操作）
struct ToastView: View {
    let toast: AppModel.Toast
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.subheadline).foregroundStyle(.white).lineLimit(3)
            if let a = toast.action {
                Spacer(minLength: 4)
                Button(a, action: action).font(.subheadline.weight(.bold)).foregroundStyle(Theme.c3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(.horizontal, 16)
    }
}

/// 在任意视图上叠一个提示条（AppModel.toast），几秒后自动消失
struct ToastHost: ViewModifier {
    @Bindable var app: AppModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = app.toast {
                ToastView(toast: t) {
                    app.toastAction?()
                    app.toast = nil
                }
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(for: .seconds(t.action == nil ? 2.6 : 6))
                    if app.toast?.id == t.id { withAnimation { app.toast = nil } }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: app.toast)
    }
}

extension View {
    func toasts(_ app: AppModel) -> some View { modifier(ToastHost(app: app)) }
}

/// 相对时间（“3 分钟前”）
func relativeTime(_ t: Double) -> String {
    guard t > 0 else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
}

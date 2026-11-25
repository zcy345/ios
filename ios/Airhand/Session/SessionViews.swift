import SwiftUI
import UIKit

/// 画面还没来、断线重连、对方离线、会话结束时盖在画面上的那一层
struct SessionOverlay: View {
    let session: RemoteSession
    let ui: SessionUIState
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(session.phase == .live ? 0.35 : 0.8).ignoresSafeArea()
            VStack(spacing: 18) {
                switch session.phase {
                case .connecting:
                    spinner(L.t("session_connecting", session.hostName))
                    button(L.t("cancel"), close)
                case .live:
                    spinner(L.t("session_waiting_video"))
                case .reconnecting:
                    spinner(L.t("session_reconnecting"))
                    button(L.t("disconnect"), close)
                case .waitingHost:
                    DeviceIcon(os: session.os, size: 64).opacity(0.7)
                    Text(L.t("session_waiting_host", session.hostName)).font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Text(L.t("session_waiting_host_detail")).font(.subheadline).foregroundStyle(Theme.sub)
                    HStack(spacing: 12) {
                        button(L.t("retry")) { session.retryNow() }
                        button(L.t("disconnect"), close)
                    }
                case .ended(let p), .failed(let p):
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 48)).foregroundStyle(Theme.sub)
                    Text(L.t("session_ended")).font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Text(Messages.problem(p)).font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                    button(L.t("close"), close)
                case .closed:
                    EmptyView()
                }
            }
            .padding(32)
            .frame(maxWidth: 460)
        }
        .preferredColorScheme(.dark)
    }

    private func spinner(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(.white)
            Text(text).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
        }
    }

    private func button(_ t: String, _ f: @escaping () -> Void) -> some View {
        Button(t, action: f).buttonStyle(SecondaryButtonStyle())
    }
}

/// 画面顶上的提示：被控端的问题（缺权限、采集失败）、只能看、剪贴板来了这类短提示
struct SessionBanner: View {
    let session: RemoteSession
    let app: AppModel
    @State private var hidden: Set<String> = []

    private var lines: [(String, String, Color)] {
        var out: [(String, String, Color)] = []
        if session.viewOnly, session.phase == .live { out.append(("viewOnly", L.t("view_only_host"), Theme.sub)) }
        for (k, n) in session.notices.sorted(by: { $0.key < $1.key }) {
            if let text = Messages.notice(n, host: session.os) { out.append((k, text, Theme.warn)) }
        }
        if let e = session.audioError { out.append(("audio", L.t("audio_playback_failed", e), Theme.warn)) }
        return out.filter { !hidden.contains($0.0) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let t = app.toast {
                HStack(spacing: 10) {
                    Text(t.text).font(.footnote.weight(.medium)).foregroundStyle(.white)
                    if let a = t.action {
                        Button(a) {
                            app.toastAction?()
                            app.toast = nil
                        }.font(.footnote.weight(.bold)).foregroundStyle(Theme.c3)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(for: .seconds(t.action == nil ? 2.4 : 6))
                    if app.toast?.id == t.id { withAnimation { app.toast = nil } }
                }
            }
            ForEach(lines, id: \.0) { k, text, color in
                Button {
                    withAnimation { _ = hidden.insert(k) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: color == Theme.warn ? "exclamationmark.triangle.fill" : "eye").foregroundStyle(color)
                        Text(text).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.leading)
                        Image(systemName: "xmark").font(.caption2).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 560)
        .animation(.spring(duration: 0.3), value: app.toast)
        .preferredColorScheme(.dark)
    }
}

/// 控制手机时画面下方的返回 / 主页 / 最近任务
struct NavKeysBar: View {
    let action: (SystemAction) -> Void

    var body: some View {
        HStack {
            Spacer()
            key("arrowtriangle.backward.fill", .back)
            Spacer()
            key("circle", .home)
            Spacer()
            key("square", .recents)
            Spacer()
        }
        .frame(height: 52)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
    }

    private func key(_ icon: String, _ a: SystemAction) -> some View {
        Button { action(a) } label: {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 64, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(L.t("action_\(a.rawValue)"))
    }
}

/// 软键盘上面的一排特殊键：Esc、Tab、Ctrl、Alt、Shift、Win（Mac 上是 ⌘）、方向键、Home / End、PgUp / PgDn、Del、F1–F12
struct KeyBar: View {
    let state: KeyboardState
    let os: OsKind
    let hide: () -> Void

    private let keys: [String] = ["Escape", "Tab", "MOD:ControlLeft", "MOD:AltLeft", "MOD:ShiftLeft", "MOD:MetaLeft",
                                  "ArrowLeft", "ArrowUp", "ArrowDown", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Delete"]
        + (1...12).map { "F\($0)" }

    var body: some View {
        VStack(spacing: 0) {
            if !state.composing.isEmpty {
                Text(state.composing).font(.callout).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.c2.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 4)
            }
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(keys, id: \.self) { k in
                            if k.hasPrefix("MOD:") {
                                let m = String(k.dropFirst(4))
                                let st = state.state(m)
                                keyButton(KeyMap.label(m, os: os), highlight: st) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    state.toggle(m)
                                }
                            } else {
                                keyButton(KeyMap.label(k, os: os), highlight: .off) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                                    state.press(k)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Button(action: hide) {
                    Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 46, height: 40)
                }
                .accessibilityLabel(L.t("hide_keyboard"))
            }
            .frame(height: 50)
            .background(.ultraThinMaterial)
        }
        .preferredColorScheme(.dark)
    }

    private func keyButton(_ label: String, highlight: KeyboardState.Sticky, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(minWidth: 42, minHeight: 36).padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(highlight == .off ? Color.white.opacity(0.12) : (highlight == .locked ? Theme.c2 : Theme.c2.opacity(0.55)))
                )
                .overlay(alignment: .bottom) {
                    if highlight == .locked { Capsule().fill(.white).frame(width: 14, height: 2).padding(.bottom, 3) }
                }
        }
        .buttonStyle(.plain)
    }
}

/// 手势说明（第一次进入远程画面时，菜单里也能打开）
struct GestureTips: View {
    let mode: Gestures.Mode
    let os: OsKind
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String, String)] {
        switch mode {
        case .trackpad:
            return [("hand.point.up.left", "g_slide", "g_move_pointer"), ("hand.tap", "g_tap", "g_left_click"),
                    ("hand.point.up.braille", "g_long_press", "g_right_click"), ("hand.draw", "g_tap_then_drag", "g_drag"),
                    ("hand.tap.fill", "g_two_tap", "g_right_click"), ("arrow.up.and.down", "g_two_slide", "g_scroll"),
                    ("arrow.up.left.and.arrow.down.right", "g_pinch", "g_zoom"), ("keyboard", "g_three_tap", "g_keyboard"),
                    ("computermouse", "g_mouse", "g_mouse_desc")]
        case .touch:
            return [("hand.tap", "g_tap", "g_click_there"), ("hand.point.up.braille", "g_long_press", "g_right_click_there"),
                    ("hand.draw", "g_slide", "g_drag"), ("hand.tap.fill", "g_two_tap", "g_right_click"),
                    ("arrow.up.and.down", "g_two_slide", "g_scroll"), ("arrow.up.left.and.arrow.down.right", "g_pinch", "g_zoom_pan"),
                    ("keyboard", "g_three_tap", "g_keyboard"), ("computermouse", "g_mouse", "g_mouse_desc")]
        default:
            return [("hand.tap", "g_tap", "g_same_as_phone"), ("hand.draw", "g_slide", "g_same_as_phone"),
                    ("arrow.up.left.and.arrow.down.right", "g_pinch", "g_same_as_phone"), ("keyboard", "g_three_tap", "g_keyboard")]
        }
    }

    private var title: String {
        switch mode {
        case .trackpad: return L.t("tips_trackpad")
        case .touch: return L.t("tips_touch")
        default: return L.t("tips_phone")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows, id: \.1) { icon, g, what in
                        HStack(spacing: 14) {
                            Image(systemName: icon).font(.title3).foregroundStyle(Theme.c3).frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.t(g)).font(.headline)
                                Text(L.t(what)).font(.subheadline).foregroundStyle(Theme.sub)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text(L.t("tips_menu"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L.t("done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

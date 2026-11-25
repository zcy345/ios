import ReplayKit
import SwiftUI
import UserNotifications

/// 共享本机：用系统的屏幕广播（ReplayKit）把这台 iPhone / iPad 的屏幕和声音给别人看。
/// 网络部分在广播扩展里（App 切到后台也照样共享），这里显示它的状态、发命令给它。
struct ShareView: View {
    @Bindable var app: AppModel
    @State private var confirmKick = false
    @State private var confirmNewCode = false
    @State private var confirmForget = false
    @State private var confirmStop = false

    private var live: HostLive? { app.sharing ? app.hostLive : nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let live {
                        sharing(live)
                    } else {
                        intro
                    }
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(
                ZStack {
                    Theme.bg
                    RadialGradient(colors: [Theme.c3.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 420)
                }.ignoresSafeArea()
            )
            .navigationTitle(L.t("tab_share"))
        }
        .onAppear {
            // 有设备连上来时广播扩展会发通知：在这里（要共享的时候）才问
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "AirhandNoNotify") { return }
            #endif
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .confirmationDialog(L.t("share_kick_all"), isPresented: $confirmKick, titleVisibility: .visible) {
            Button(L.t("share_kick_all"), role: .destructive) { HostCommand.send("kickAll") }
        } message: { Text(L.t("share_kick_text")) }
        .confirmationDialog(L.t("share_new_code_title"), isPresented: $confirmNewCode, titleVisibility: .visible) {
            Button(L.t("share_new_code"), role: .destructive) { app.newHostCode() }
        } message: { Text(L.t("share_new_code_text")) }
        .confirmationDialog(L.t("share_forget_paired_title"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button(L.t("forget"), role: .destructive) { app.forgetPaired() }
        } message: { Text(L.t("share_forget_paired_text")) }
        .confirmationDialog(L.t("share_stop_title"), isPresented: $confirmStop, titleVisibility: .visible) {
            Button(L.t("share_stop"), role: .destructive) { HostCommand.send("stop") }
        } message: { Text(L.t("share_stop_text")) }
    }

    // ── 没在共享 ──

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.softGradient).frame(width: 64, height: 64)
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(L.t("share_intro_title")).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                    Text(L.t("share_intro_body")).font(.subheadline).foregroundStyle(Theme.sub)
                    Label(L.t("share_view_only"), systemImage: "eye").font(.footnote).foregroundStyle(Theme.sub)
                    Label(L.t("share_audio_note"), systemImage: "speaker.wave.2").font(.footnote).foregroundStyle(Theme.sub)
                }
            }
            if !SharedStore.hasGroup {
                Label(L.t("share_no_group"), systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.warn)
            }
            BroadcastButton(title: L.t("share_start"))
                .frame(height: 56)
            Text(L.t("share_start_hint")).font(.footnote).foregroundStyle(Theme.sub).frame(maxWidth: .infinity)
            if let c = SavedHostCode.load() {
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.t("share_your_code")).font(.caption).foregroundStyle(Theme.sub)
                            Text(Code.format(String(c.code))).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Theme.text)
                        }
                        Spacer()
                        Image(systemName: "lock.fill").foregroundStyle(Theme.faint)
                    }
                }
            }
        }
    }

    // ── 在共享 ──

    @ViewBuilder
    private func sharing(_ live: HostLive) -> some View {
        HStack {
            switch live.server {
            case "connected": StatusPill(color: Theme.good, text: live.viewers.isEmpty ? L.t("share_ready") : L.t("share_sharing"))
            case "disconnected": StatusPill(color: Theme.bad, text: live.serverProblem ?? L.t("server_offline"))
            default: StatusPill(color: Theme.warn, text: L.t("share_connecting"), spinning: true)
            }
            Spacer()
        }
        codeCard(live)
        viewers(live)
        VStack(spacing: 10) {
            Button { confirmNewCode = true } label: { Label(L.t("share_new_code"), systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButtonStyle())
            Button { if live.viewers.isEmpty { HostCommand.send("stop") } else { confirmStop = true } } label: {
                Label(L.t("share_stop"), systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.bad))
        }
    }

    private func codeCard(_ live: HostLive) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("share_your_code")).font(.subheadline).foregroundStyle(Theme.sub)
                    if let c = live.code {
                        Text(Code.format(String(c)))
                            .font(.system(size: 46, weight: .heavy, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.gradient)
                            .textSelection(.enabled)
                    } else {
                        ProgressView().tint(Theme.c3).frame(height: 54)
                    }
                }
                Divider().overlay(Theme.stroke)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L.t("share_pairing")).font(.subheadline).foregroundStyle(Theme.sub)
                        Spacer()
                        Button(L.t("share_pairing_new")) { HostCommand.send("newPairingCode") }.font(.caption.weight(.semibold))
                    }
                    Text(live.pairingCode.map { Code.format($0) } ?? "— — —")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(live.pairingLocked ? Theme.faint : Theme.text)
                    Text(live.pairingLocked ? L.t("share_pairing_locked") : L.t("share_pairing_desc"))
                        .font(.caption).foregroundStyle(live.pairingLocked ? Theme.warn : Theme.sub)
                    if live.pairedCount > 0 {
                        Button(L.t("share_forget_paired", live.pairedCount)) { confirmForget = true }.font(.caption.weight(.semibold))
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = live.code.map { Code.format(String($0)) } ?? ""
                        app.show(L.t("copied"))
                    } label: { Label(L.t("copy"), systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle())
                    if let c = live.code {
                        ShareLink(item: L.t("share_code_message", Code.format(String(c)), live.pairingCode.map { Code.format($0) } ?? "")) {
                            Label(L.t("share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private func viewers(_ live: HostLive) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: L.t("share_viewers"))
                Spacer()
                if !live.viewers.isEmpty {
                    Button(L.t("share_kick_all")) { confirmKick = true }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.bad)
                }
            }
            if live.viewers.isEmpty {
                Card { Label(L.t("share_no_viewers"), systemImage: "person.crop.circle.badge.questionmark").foregroundStyle(Theme.sub) }
            } else {
                ForEach(live.viewers) { v in
                    Card {
                        HStack(spacing: 12) {
                            DeviceIcon(os: .unknown, size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(v.name.isEmpty ? L.t("unknown_device") : v.name).font(.headline).foregroundStyle(Theme.text)
                                    if v.justPaired {
                                        Text(L.t("share_paired_badge")).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Theme.c2.opacity(0.3), in: Capsule()).foregroundStyle(Theme.c3)
                                    }
                                }
                                Text("\(v.ip) · \(L.t("session_safety", v.safety))").font(.caption).foregroundStyle(Theme.sub)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

/// 系统的“开始直播”按钮（RPSystemBroadcastPickerView）套上自己的样子：只有它能弹出系统的广播选择框
struct BroadcastButton: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.gradient)
            Label(title, systemImage: "record.circle").font(.headline).foregroundStyle(.white)
            BroadcastPicker().opacity(0.02)
        }
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    final class Picker: RPSystemBroadcastPickerView {
        override func layoutSubviews() {
            super.layoutSubviews()
            for case let b as UIButton in subviews { b.frame = bounds }
        }
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = Picker(frame: .zero)
        v.preferredExtension = (Bundle.main.object(forInfoDictionaryKey: "AirhandBroadcastExtension") as? String) ?? "app.airhand.ios.broadcast"
        v.showsMicrophoneButton = false
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

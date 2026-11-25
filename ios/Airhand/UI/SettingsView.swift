import SwiftUI

/// 设置：服务器、本机、远程控制的默认值、数据、关于
struct SettingsView: View {
    @Bindable var app: AppModel
    @State private var server = ""
    @State private var fingerprint = ""
    @State private var name = ""
    @State private var confirmNewCode = false
    @State private var confirmForget = false
    @State private var confirmClear = false
    @State private var showTips = false
    @State private var hostCode = SavedHostCode.load()
    @State private var paired = PairingFile.pairedCount

    private var serverError: String? {
        let s = server.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        guard let i = s.lastIndex(of: ":"), let port = Int(s[s.index(after: i)...]), port > 0, port < 65536, i != s.startIndex else {
            return L.t("server_address_invalid")
        }
        return nil
    }

    private var fpError: String? {
        let f = fingerprint.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? nil : (Native.checkFingerprint(f) == nil ? nil : L.t("fingerprint_invalid"))
    }

    private var dirty: Bool {
        server.trimmingCharacters(in: .whitespaces) != app.settings.server || fingerprint.trimmingCharacters(in: .whitespaces) != app.settings.fingerprint
            || name.trimmingCharacters(in: .whitespaces) != app.settings.deviceName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L.t("server_address"), text: $server, prompt: Text("relay.example.com:4433"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        if let e = serverError { Text(e).font(.caption).foregroundStyle(Theme.bad) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L.t("server_fingerprint"), text: $fingerprint, prompt: Text(L.t("server_fingerprint")), axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                        if let e = fpError {
                            Text(e).font(.caption).foregroundStyle(Theme.bad)
                        } else if fingerprint.isEmpty {
                            Text(app.settings.trustFp.map { L.t("fingerprint_learned", String($0.prefix(12))) } ?? L.t("fingerprint_none"))
                                .font(.caption).foregroundStyle(Theme.sub)
                        }
                    }
                } header: {
                    Text(L.t("settings_server"))
                } footer: {
                    Text(L.t("fingerprint_hint"))
                }

                Section(L.t("settings_this_device")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L.t("device_name"), text: $name, prompt: Text(AppModel.deviceName(AppSettings())))
                        Text(L.t("device_name_hint")).font(.caption).foregroundStyle(Theme.sub)
                    }
                    Button { confirmNewCode = true } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t("share_new_code")).foregroundStyle(Theme.text)
                            Text(currentCode).font(.caption).foregroundStyle(Theme.sub)
                        }
                    }
                    Button { if paired > 0 { confirmForget = true } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t("settings_paired")).foregroundStyle(Theme.text)
                            Text(paired > 0 ? L.t("settings_paired_count", paired) : L.t("settings_paired_none"))
                                .font(.caption).foregroundStyle(Theme.sub)
                        }
                    }
                }

                if dirty {
                    Section {
                        Button(L.t("save")) { save() }
                            .disabled(serverError != nil || fpError != nil)
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    } footer: {
                        Text(L.t("server_restart_note"))
                    }
                }

                Section(L.t("settings_remote")) {
                    Picker(L.t("default_quality"), selection: $app.settings.preset) {
                        ForEach(Preset.allCases) { p in
                            Text(L.t("preset_\(p.rawValue)")).tag(p.rawValue)
                        }
                    }
                    Picker(L.t("codec"), selection: $app.settings.codec) {
                        Text(L.t("codec_auto")).tag("")
                        ForEach(VideoDecoder.decodable) { c in Text(c.label).tag(c.wire) }
                    }
                    Picker(L.t("touch_mode"), selection: $app.settings.touchMode) {
                        Text(L.t("mode_auto")).tag("auto")
                        Text(L.t("mode_trackpad")).tag("trackpad")
                        Text(L.t("mode_touch")).tag("touch")
                    }
                    Toggle(isOn: $app.settings.audio) { labeled("play_audio", "play_audio_desc") }
                    Toggle(isOn: $app.settings.avSync) { labeled("av_sync", "av_sync_desc") }
                    Toggle(isOn: $app.settings.navKeys) { labeled("nav_keys", "nav_keys_desc") }
                    Toggle(isOn: $app.settings.localCursor) { labeled("local_cursor", "local_cursor_desc") }
                    Button(L.t("show_tips")) { showTips = true }
                }

                Section {
                    Button(role: .destructive) { confirmClear = true } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t("clear_devices"))
                            Text(L.t("clear_devices_desc", app.devices.list.count)).font(.caption).foregroundStyle(Theme.sub)
                        }
                    }
                    .disabled(app.devices.list.isEmpty)
                } header: {
                    Text(L.t("settings_data"))
                } footer: {
                    Text(L.t("data_note"))
                }

                Section(L.t("settings_about")) {
                    LabeledContent(L.t("version"), value: L.t("version_value", AppModel.version, Native.protocolVersion))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(L.t("tab_settings"))
        }
        .onAppear(perform: load)
        .confirmationDialog(L.t("share_new_code_title"), isPresented: $confirmNewCode, titleVisibility: .visible) {
            Button(L.t("share_new_code"), role: .destructive) {
                app.newHostCode()
                hostCode = SavedHostCode.load()
                paired = PairingFile.pairedCount
            }
        } message: { Text(L.t("share_new_code_text")) }
        .confirmationDialog(L.t("share_forget_paired_title"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button(L.t("forget"), role: .destructive) {
                app.forgetPaired()
                paired = 0
            }
        } message: { Text(L.t("share_forget_paired_text")) }
        .confirmationDialog(L.t("clear_devices"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L.t("delete"), role: .destructive) {
                app.closeSession()
                app.devices.clear()
            }
        } message: { Text(L.t("clear_devices_confirm")) }
        .sheet(isPresented: $showTips) { GestureTips(mode: .trackpad, os: .windows).presentationDetents([.large]) }
    }

    private var currentCode: String {
        if let c = app.hostLive?.code, app.sharing { return L.t("settings_current_code", Code.format(String(c))) }
        if let c = hostCode { return L.t("settings_current_code", Code.format(String(c.code))) }
        return L.t("settings_no_code")
    }

    private func labeled(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L.t(t))
            Text(L.t(d)).font(.caption).foregroundStyle(Theme.sub)
        }
    }

    private func load() {
        server = app.settings.server
        fingerprint = app.settings.fingerprint
        name = app.settings.deviceName
        hostCode = SavedHostCode.load()
        paired = PairingFile.pairedCount
    }

    private func save() {
        var s = app.settings
        let newServer = server.trimmingCharacters(in: .whitespaces)
        let newFp = fingerprint.trimmingCharacters(in: .whitespaces)
        if newServer != s.server || newFp != s.fingerprint {
            // 换了服务器或者重新保存了指纹：忘掉第一次连接时记下的证书
            s.trustServer = nil
            s.trustFp = nil
        }
        s.server = newServer
        s.fingerprint = newFp
        s.deviceName = name.trimmingCharacters(in: .whitespaces)
        app.settings = s
        app.closeSession()
        app.controller.restart()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

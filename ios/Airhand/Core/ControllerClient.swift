import Foundation
import Observation
import UIKit

/// 控制端与中转服务器的连接（Rust 的 `ControllerService`）：应用在前台、或者有会话时保持连接，
/// 掉线后 Rust 那边自动重连。应用退到后台、也没有会话一段时间后断开，省电。
@Observable
final class ControllerClient {
    private(set) var server: ServerState = .connecting
    /// 设置不完整（没有服务器地址）等启动失败的原因
    private(set) var startError: String?

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var _handle: Int64 = 0
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var stopWork: DispatchWorkItem?
    @ObservationIgnored private let settings: () -> AppSettings
    @ObservationIgnored private let sessionOnly: Bool
    @ObservationIgnored private var observedFingerprint: String?
    var fingerprint: String? { lock.lock(); defer { lock.unlock() }; return observedFingerprint }
    @ObservationIgnored private let learnTrust: (String, String) -> Void
    @ObservationIgnored private var hostOnlineHandlers: [UUID: (String) -> Void] = [:]
    @ObservationIgnored private var serverHandlers: [UUID: (ServerState) -> Void] = [:]

    init(sessionOnly: Bool = false, settings: @escaping () -> AppSettings, learnTrust: @escaping (String, String) -> Void) {
        self.sessionOnly = sessionOnly
        self.settings = settings
        self.learnTrust = learnTrust
    }

    /// 当前的句柄，没有连接（例如设置不对）时为 0
    var handle: Int64 { lock.lock(); defer { lock.unlock() }; return _handle }

    /// 当前的服务器状态（任意线程）
    @ObservationIgnored private var _state: ServerState = .connecting
    var state: ServerState { lock.lock(); defer { lock.unlock() }; return _state }

    func onHostOnline(_ f: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); hostOnlineHandlers[id] = f; lock.unlock()
        return id
    }

    func onServer(_ f: @escaping (ServerState) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); serverHandlers[id] = f; lock.unlock()
        return id
    }

    func removeHandler(_ id: UUID) {
        lock.lock(); hostOnlineHandlers[id] = nil; serverHandlers[id] = nil; lock.unlock()
    }

    func setForeground(_ fg: Bool) {
        lock.lock()
        foreground = fg
        lock.unlock()
        if fg {
            stopWork?.cancel()
            start()
        } else {
            scheduleStop()
        }
    }

    /// 会话开始用这条连接（会话结束时 release）
    func acquire() {
        lock.lock(); users += 1; lock.unlock()
        DispatchQueue.main.async { self.stopWork?.cancel() }
        start()
    }

    func release() {
        lock.lock(); users = max(0, users - 1); lock.unlock()
        if sessionOnly { stop(); return }
        DispatchQueue.main.async { self.scheduleStop() }
    }

    /// 服务器设置变了：用新设置重新连接（正在进行的会话会断开）
    func restart() {
        stop()
        lock.lock(); let need = foreground || users > 0; lock.unlock()
        if need { start() }
    }

    private func scheduleStop() {
        lock.lock(); let idle = !foreground && users == 0; lock.unlock()
        guard idle else { return }
        stopWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); let idle = !self.foreground && self.users == 0; self.lock.unlock()
            if idle { self.stop() }
        }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
    }

    private func start() {
        lock.lock()
        if _handle != 0 { lock.unlock(); return }
        let s = settings()
        guard !s.server.trimmingCharacters(in: .whitespaces).isEmpty else {
            lock.unlock()
            setState(.disconnected(Problem(kind: "failed", detail: L.t("server_not_set"))), error: L.t("server_not_set"))
            return
        }
        let cfg: JSON = [
            "server": s.server, "fingerprint": s.fingerprint, "trust": s.trustJson,
            "name": AppModel.deviceName(s), "os": AppModel.osName, "identity": IdentityStore.load() ?? NSNull(),
        ]
        do {
            let h = try Native.ctlStart(Json.string(cfg))
            _handle = h
            _state = .connecting
            lock.unlock()
            setState(.connecting, error: nil)
            let t = Thread { [weak self] in self?.pump(h) }
            t.name = "airhand-ctl-events"
            t.start()
        } catch {
            lock.unlock()
            Log.warn("can't start the controller: \(error)")
            setState(.disconnected(Problem(kind: "failed", detail: "\(error)")), error: "\(error)")
        }
    }

    private func stop() {
        lock.lock()
        let h = _handle
        _handle = 0
        _state = .connecting
        lock.unlock()
        if h != 0 {
            DispatchQueue.global().async { Native.ctlStop(h) }
        }
        DispatchQueue.main.async { self.server = .connecting }
    }

    private func setState(_ s: ServerState, error: String?) {
        lock.lock()
        _state = s
        let handlers = Array(serverHandlers.values)
        lock.unlock()
        handlers.forEach { $0(s) }
        DispatchQueue.main.async {
            self.server = s
            self.startError = error
        }
    }

    private func pump(_ h: Int64) {
        while handle == h {
            guard let text = Native.ctlPollEvent(h, 500), let e = Json.parse(text) else { continue }
            switch e.str("type") {
            case "server":
                if handle == h { setState(ServerState.parse(e.obj("state")), error: nil) }
            case "hostOnline":
                let code = String(e.int("code") ?? 0)
                lock.lock(); let handlers = Array(hostOnlineHandlers.values); lock.unlock()
                handlers.forEach { $0(code) }
            case "serverTrust":
                if let server = e.str("server"), let fp = e.str("fp") {
                    lock.lock(); observedFingerprint = fp; lock.unlock()
                    DispatchQueue.main.async { self.learnTrust(server, fp) }
                }
            case "identity":
                if let k = e.str("key") { IdentityStore.save(k) }
            default: break
            }
        }
    }
}

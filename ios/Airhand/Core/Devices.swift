import Foundation
import Observation

/// “我的设备”里的一台设备：连接成功时自动保存，下次点一下就连
struct SavedDevice: Codable, Equatable, Identifiable {
    var code: String
    /// 对方报告的名称
    var name: String
    /// 用户起的名字（优先显示）
    var alias: String = ""
    var hostOs: String = ""
    var lastConnected: Double = 0
    /// 重连凭证（32 位十六进制）
    var resume: String = ""
    /// 对方的端到端加密公钥（64 位十六进制）：之后只认它
    var hostKey: String? = nil
    var directFingerprint: String? = nil

    var id: String { code }
    var title: String { !alias.isEmpty ? alias : (!name.isEmpty ? name : Code.format(code)) }
    var os: OsKind { OsKind.of(hostOs) }
}

@Observable
final class DeviceStore {
    private(set) var list: [SavedDevice] = []
    private let file = "devices.json"

    init() {
        list = SharedStore.read(file, as: [SavedDevice].self) ?? []
        sort()
    }

    func get(_ code: String) -> SavedDevice? { list.first { $0.code == code } }

    /// 开始会话时记下（名称、系统、凭证、对方公钥）
    func connected(code: String, name: String, os: String, resume: String, hostKey: String?, directFingerprint: String?) {
        var d = get(code) ?? SavedDevice(code: code, name: name)
        if !name.isEmpty { d.name = name }
        if !os.isEmpty { d.hostOs = os }
        if !resume.isEmpty { d.resume = resume }
        if let hostKey, !hostKey.isEmpty { d.hostKey = hostKey }
        if let directFingerprint { d.directFingerprint = directFingerprint }
        d.lastConnected = Date().timeIntervalSince1970
        list.removeAll { $0.code == code }
        list.append(d)
        save()
    }

    func rename(_ code: String, to alias: String) {
        guard let i = list.firstIndex(where: { $0.code == code }) else { return }
        list[i].alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func remove(_ code: String) {
        list.removeAll { $0.code == code }
        save()
    }

    func restore(_ d: SavedDevice) {
        list.removeAll { $0.code == d.code }
        list.append(d)
        save()
    }

    func clear() {
        list = []
        save()
    }

    private func sort() { list.sort { $0.lastConnected > $1.lastConnected } }

    private func save() {
        sort()
        SharedStore.write(file, list)
    }
}

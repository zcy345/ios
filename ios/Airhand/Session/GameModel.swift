import Foundation
import Observation

/// 游戏按键：叠在画面上的按钮和摇杆（控制电脑时用），和 Android 版的功能一样。
/// 按钮发的是协议里已有的按键、鼠标键、滚轮和相对移动，被控端不用做什么。
struct GameItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case button, stick }

    var id = UUID()
    var kind: Kind
    /// 中心在画面上的位置（0..1）
    var x: Double
    var y: Double
    /// 直径（点）
    var size: Double
    /// 按钮：按下的键（最多 3 个，组合键按顺序按下、倒序松开）：W3C 的 code，或者 `mouse:left`、`wheel:up` 这样的；
    /// 摇杆：上、左、下、右
    var keys: [String]
    var label: String = ""
    /// 点一下切换（按下 / 松开），否则按住
    var toggle = false
    /// 按着的时候拖动可以转视角
    var look = false
    /// 摇杆推出边缘时加按的键
    var sprint: String? = nil
    /// 摇杆从拇指落下的地方开始
    var floating = true

    static let wasd = ["KeyW", "KeyA", "KeyS", "KeyD"]
    static let arrows = ["ArrowUp", "ArrowLeft", "ArrowDown", "ArrowRight"]

    /// 按钮上显示的文字
    func title(os: OsKind) -> String {
        if !label.isEmpty { return label }
        if kind == .stick { return keys == GameItem.arrows ? "↑←↓→" : "WASD" }
        return keys.map { GameItem.keyLabel($0, os: os) }.joined(separator: "+")
    }

    static func keyLabel(_ k: String, os: OsKind) -> String {
        switch k {
        case "mouse:left": return L.t("game_mouse_left")
        case "mouse:right": return L.t("game_mouse_right")
        case "mouse:middle": return L.t("game_mouse_middle")
        case "mouse:back": return "M4"
        case "mouse:forward": return "M5"
        case "wheel:up": return L.t("game_wheel_up")
        case "wheel:down": return L.t("game_wheel_down")
        default: return KeyMap.label(k, os: os)
        }
    }
}

struct GameLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var opacity: Double = 0.65
    var lookSpeed: Double = 1.0
    var haptics = true
    var items: [GameItem] = []
}

/// 每台设备的选择：开没开、用哪个方案
struct GamePref: Codable, Equatable {
    var enabled = false
    var layout: UUID?
}

@Observable
final class GameStore {
    private(set) var layouts: [GameLayout] = []
    private(set) var prefs: [String: GamePref] = [:]
    var tipsShown = false

    private struct File: Codable {
        var layouts: [GameLayout]
        var prefs: [String: GamePref]
        var tipsShown: Bool?
    }

    private let file = "game.json"

    init() {
        if let f = SharedStore.read(file, as: File.self) {
            layouts = f.layouts
            prefs = f.prefs
            tipsShown = f.tipsShown ?? false
        }
    }

    private func save() { SharedStore.write(file, File(layouts: layouts, prefs: prefs, tipsShown: tipsShown)) }

    func markTipsShown() { tipsShown = true; save() }

    func pref(_ code: String) -> GamePref { prefs[code] ?? GamePref() }

    /// 这台设备现在用的方案（开着才有）
    func active(_ code: String) -> GameLayout? {
        let p = pref(code)
        guard p.enabled else { return nil }
        return layouts.first { $0.id == p.layout } ?? layouts.first
    }

    func setEnabled(_ code: String, _ on: Bool) {
        var p = pref(code)
        p.enabled = on
        if on, p.layout == nil || !layouts.contains(where: { $0.id == p.layout }) {
            if layouts.isEmpty { layouts.append(GameTemplates.shooter()) }
            p.layout = layouts.first?.id
        }
        prefs[code] = p
        save()
    }

    func select(_ code: String, _ id: UUID) {
        var p = pref(code)
        p.layout = id
        prefs[code] = p
        save()
    }

    @discardableResult
    func add(_ l: GameLayout) -> GameLayout {
        layouts.append(l)
        save()
        return l
    }

    func update(_ l: GameLayout) {
        guard let i = layouts.firstIndex(where: { $0.id == l.id }) else { return }
        layouts[i] = l
        save()
    }

    func duplicate(_ l: GameLayout) -> GameLayout {
        var c = l
        c.id = UUID()
        c.name = L.t("game_copy_name", l.name)
        c.items = l.items.map { var i = $0; i.id = UUID(); return i }
        return add(c)
    }

    func delete(_ id: UUID) {
        layouts.removeAll { $0.id == id }
        save()
    }
}

/// 模板：射击、技能、方向键、空白（坐标按横屏摆）
enum GameTemplates {
    static func button(_ x: Double, _ y: Double, _ size: Double, _ keys: [String], label: String = "", toggle: Bool = false, look: Bool = false) -> GameItem {
        GameItem(kind: .button, x: x, y: y, size: size, keys: keys, label: label, toggle: toggle, look: look)
    }

    static func stick(_ x: Double, _ y: Double, _ keys: [String], sprint: String? = nil) -> GameItem {
        GameItem(kind: .stick, x: x, y: y, size: 150, keys: keys, sprint: sprint, floating: true)
    }

    static func shooter() -> GameLayout {
        let zh = L.zh
        return GameLayout(name: L.t("game_tpl_shooter"), items: [
            stick(0.15, 0.70, GameItem.wasd, sprint: "ShiftLeft"),
            button(0.86, 0.66, 86, ["mouse:left"], label: zh ? "开火" : "Fire", look: true),
            button(0.93, 0.27, 60, ["mouse:right"], label: zh ? "开镜" : "Aim"),
            button(0.93, 0.86, 62, ["Space"], label: zh ? "跳" : "Jump"),
            button(0.79, 0.88, 54, ["KeyC"], label: zh ? "蹲" : "Crouch"),
            button(0.74, 0.70, 50, ["KeyR"], label: zh ? "换弹" : "Reload"),
            button(0.70, 0.88, 46, ["KeyE"]),
            button(0.64, 0.75, 46, ["KeyQ"]),
            button(0.70, 0.12, 44, ["Digit1"]),
            button(0.77, 0.12, 44, ["Digit2"]),
            button(0.84, 0.12, 44, ["Digit3"]),
            button(0.06, 0.13, 44, ["Tab"]),
            button(0.13, 0.13, 44, ["Escape"]),
        ])
    }

    static func skills() -> GameLayout {
        GameLayout(name: L.t("game_tpl_skills"), items: [
            button(0.62, 0.86, 58, ["KeyQ"]),
            button(0.71, 0.86, 58, ["KeyW"]),
            button(0.80, 0.86, 58, ["KeyE"]),
            button(0.90, 0.80, 70, ["KeyR"]),
            button(0.92, 0.58, 50, ["KeyD"]),
            button(0.84, 0.64, 50, ["KeyF"]),
            button(0.06, 0.40, 42, ["Digit1"]),
            button(0.06, 0.52, 42, ["Digit2"]),
            button(0.06, 0.64, 42, ["Digit3"]),
            button(0.06, 0.76, 42, ["Digit4"]),
            button(0.06, 0.13, 44, ["KeyB"]),
            button(0.52, 0.88, 50, ["Space"]),
        ])
    }

    static func arrows() -> GameLayout {
        GameLayout(name: L.t("game_tpl_arrows"), items: [
            stick(0.16, 0.68, GameItem.arrows),
            button(0.72, 0.80, 64, ["KeyZ"]),
            button(0.82, 0.68, 64, ["KeyX"]),
            button(0.92, 0.56, 64, ["KeyC"]),
            button(0.84, 0.90, 56, ["Space"]),
            button(0.94, 0.86, 50, ["Enter"]),
            button(0.06, 0.13, 44, ["Escape"]),
        ])
    }

    static func blank() -> GameLayout { GameLayout(name: L.t("game_tpl_blank")) }
}

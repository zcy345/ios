import UIKit

/// 游戏按键发出去的东西：同一个键被几处按着（摇杆的 W 和一个 W 按钮）时都松开才松开
final class GameOutput {
    var send: ([JSON]) -> Void = { _ in }
    /// 拖动转视角：移动了多少点（交给画面换算成相对移动）
    var look: (CGFloat, CGFloat) -> Void = { _, _ in }
    var haptics = true
    private var counts: [String: Int] = [:]
    private var wheels: [String: Timer] = [:]

    func press(_ k: String) {
        counts[k, default: 0] += 1
        guard counts[k] == 1 else { return }
        if k.hasPrefix("mouse:") {
            send([Input.button(String(k.dropFirst(6)), true)])
        } else if k.hasPrefix("wheel:") {
            let dy = k == "wheel:up" ? 120 : -120
            send([Input.wheel(0, dy)])
            // 按着就一格一格地转下去
            wheels[k] = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.send([Input.wheel(0, dy)]) }
        } else {
            send([Input.key(k, true)])
        }
    }

    func release(_ k: String) {
        guard let n = counts[k] else { return }
        if n > 1 { counts[k] = n - 1; return }
        counts[k] = nil
        if k.hasPrefix("mouse:") {
            send([Input.button(String(k.dropFirst(6)), false)])
        } else if k.hasPrefix("wheel:") {
            wheels.removeValue(forKey: k)?.invalidate()
        } else {
            send([Input.key(k, false)])
        }
    }

    func releaseAll() {
        for k in Array(counts.keys) {
            counts[k] = 1
            release(k)
        }
    }

    func tick() {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }
}

/// 叠在画面上的按钮和摇杆。空白处不拦触摸（交给下面的画面）
final class GameLayerView: UIView {
    let output = GameOutput()
    private(set) var layout: GameLayout?
    private var controls: [GameControl] = []
    var os: OsKind = .windows

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ l: GameLayout?) {
        if l == layout { return }
        output.releaseAll()
        controls.forEach { $0.removeFromSuperview() }
        controls.removeAll()
        layout = l
        guard let l else { return }
        output.haptics = l.haptics
        for item in l.items {
            let c: GameControl = item.kind == .stick ? GameStick(item: item, output: output) : GameButton(item: item, output: output, os: os)
            c.alpha = l.opacity
            addSubview(c)
            controls.append(c)
        }
        setNeedsLayout()
    }

    /// 打开菜单、切到后台、断线、打开键盘：按着的键全部松开（包括切换着的）
    func releaseAll() {
        controls.forEach { $0.reset() }
        output.releaseAll()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets)
        for c in controls {
            let s = c.item.size * (c.item.kind == .stick ? 1.35 : 1)
            let center = CGPoint(x: area.minX + area.width * c.item.x, y: area.minY + area.height * c.item.y)
            c.frame = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }
}

class GameControl: UIView {
    let item: GameItem
    let output: GameOutput

    init(item: GameItem, output: GameOutput) {
        self.item = item
        self.output = output
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        isExclusiveTouch = false
    }

    required init?(coder: NSCoder) { fatalError() }
    func reset() {}
}

/// 按钮：按住就是按着那个键；“点一下切换”的点一下按下、再点一下松开。手指滑出去也不松开
final class GameButton: GameControl {
    private let label = UILabel()
    private let ring = CAShapeLayer()
    private var down = false
    private var toggled = false
    private var lastPoint: CGPoint?

    init(item: GameItem, output: GameOutput, os: OsKind) {
        super.init(item: item, output: output)
        backgroundColor = UIColor(white: 0.08, alpha: 0.55)
        layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        layer.borderWidth = 1.5
        label.text = item.title(os: os)
        label.textColor = .white
        label.font = .systemFont(ofSize: max(11, min(18, item.size * 0.26)), weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.textAlignment = .center
        addSubview(label)
        ring.fillColor = nil
        ring.strokeColor = UIColor(red: 0.07, green: 0.83, blue: 0.93, alpha: 1).cgColor
        ring.lineWidth = 3
        ring.isHidden = true
        layer.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        label.frame = bounds.insetBy(dx: 6, dy: 6)
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: -3, dy: -3)).cgPath
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = touches.first?.location(in: self)
        output.tick()
        if item.toggle {
            toggled.toggle()
            if toggled { item.keys.forEach(output.press) } else { item.keys.reversed().forEach(output.release) }
            ring.isHidden = !toggled
        } else if !down {
            down = true
            item.keys.forEach(output.press)
        }
        setPressed(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard item.look, let t = touches.first else { return }
        let p = t.location(in: self)
        if let last = lastPoint { output.look(p.x - last.x, p.y - last.y) }
        lastPoint = p
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { up() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { up() }

    private func up() {
        lastPoint = nil
        setPressed(false)
        if !item.toggle, down {
            down = false
            item.keys.reversed().forEach(output.release)
        }
    }

    override func reset() {
        down = false
        toggled = false
        ring.isHidden = true
        setPressed(false)
    }

    private func setPressed(_ p: Bool) {
        UIView.animate(withDuration: 0.08) {
            self.transform = p ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            self.backgroundColor = p ? UIColor(red: 0.36, green: 0.49, blue: 1, alpha: 0.75) : UIColor(white: 0.08, alpha: 0.55)
        }
    }
}

/// 摇杆：8 个方向（斜着推同时按两个），方向边界和中间的死区都有回差；推出边缘时可以加按一个键
final class GameStick: GameControl {
    private let base = UIView()
    private let knob = UIView()
    private var origin: CGPoint = .zero
    private var dir: Int? // 0..7，0 = 右，逆时针
    private var sprinting = false
    private var active = false

    override init(item: GameItem, output: GameOutput) {
        super.init(item: item, output: output)
        base.backgroundColor = UIColor(white: 0.08, alpha: 0.45)
        base.layer.borderColor = UIColor(white: 1, alpha: 0.3).cgColor
        base.layer.borderWidth = 1.5
        base.isUserInteractionEnabled = false
        knob.backgroundColor = UIColor(white: 1, alpha: 0.75)
        knob.isUserInteractionEnabled = false
        addSubview(base)
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var radius: CGFloat { item.size / 2 }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !active { origin = CGPoint(x: bounds.midX, y: bounds.midY) }
        place(knobAt: origin)
    }

    private func place(knobAt p: CGPoint) {
        base.frame = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        base.layer.cornerRadius = radius
        let k = radius * 0.8
        knob.frame = CGRect(x: p.x - k / 2, y: p.y - k / 2, width: k, height: k)
        knob.layer.cornerRadius = k / 2
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        active = true
        origin = item.floating ? t.location(in: self) : CGPoint(x: bounds.midX, y: bounds.midY)
        update(t.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { update(t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }

    override func reset() {
        set(dir: nil)
        setSprint(false)
        active = false
        origin = CGPoint(x: bounds.midX, y: bounds.midY)
        place(knobAt: origin)
    }

    private func update(_ p: CGPoint) {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let dist = hypot(dx, dy)
        let clamped = dist > radius ? CGPoint(x: origin.x + dx / dist * radius, y: origin.y + dy / dist * radius) : p
        place(knobAt: clamped)
        // 死区有回差：按着方向时 0.18 以下才松开，没按时 0.28 以上才按下
        let dead = radius * (dir == nil ? 0.28 : 0.18)
        if dist < dead {
            set(dir: nil)
            setSprint(false)
            return
        }
        let angle = atan2(-dy, dx) // 向上为正
        var a = angle < 0 ? angle + 2 * .pi : angle
        let sector = CGFloat.pi / 4
        if let d = dir {
            // 方向边界有回差：离开当前方向的扇区再多 8° 才换
            let center = CGFloat(d) * sector
            var diff = abs(a - center)
            if diff > .pi { diff = 2 * .pi - diff }
            if diff <= sector / 2 + .pi / 22.5 { a = center }
        }
        let next = Int((a / sector).rounded()) % 8
        set(dir: next)
        if item.sprint != nil {
            if dist > radius * 0.95 { setSprint(true) } else if dist < radius * 0.8 { setSprint(false) }
        }
    }

    /// 方向 → 按着的键（keys：上、左、下、右）
    private func keys(_ d: Int?) -> [String] {
        guard let d, item.keys.count == 4 else { return [] }
        let up = item.keys[0], left = item.keys[1], down = item.keys[2], right = item.keys[3]
        return [[right], [up, right], [up], [up, left], [left], [down, left], [down], [down, right]][d]
    }

    private func set(dir d: Int?) {
        guard d != dir else { return }
        let old = Set(keys(dir)), new = Set(keys(d))
        for k in old.subtracting(new) { output.release(k) }
        for k in keys(d) where !old.contains(k) { output.press(k) }
        if dir == nil && d != nil { output.tick() }
        dir = d
    }

    private func setSprint(_ on: Bool) {
        guard on != sprinting, let s = item.sprint else { return }
        sprinting = on
        if on { output.press(s); output.tick() } else { output.release(s) }
    }
}

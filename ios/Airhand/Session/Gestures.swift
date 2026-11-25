import CoreGraphics
import Foundation

/// 把手指的动作变成远端的鼠标操作（纯逻辑，和 Android 的 Gestures.kt 是同一套规则）。
///
/// **触控板**（默认用于电脑）：单指滑动移动指针（慢速精细、快速加速）；单击 = 左键，双击 = 双击；长按 = 右键；
/// 点一下再按住拖动 = 按住左键拖动；双指点击 = 右键；双指拖动 = 滚动（松手后惯性）；双指捏合 = 放大画面。
/// **触屏**：点哪里就是哪里；长按 = 右键；单指拖动 = 按住左键拖动；双指拖动 = 滚动；双指捏合 = 放大 / 移动画面。
/// **多点触摸**（对方是手机，能接收触摸）：每个手指原样传过去。
/// **直通**（对方是手机，不能接收多点触摸）：一个手指传过去，双指只缩放本机的画面。
/// 三指点击 = 打开 / 收起键盘。
/// **相对移动**（`relative`：被控端的光标隐藏了或者锁定了鼠标）：只发移动了多少；
/// **转视角**（`lookGain`：开着游戏按键）：拖动只转视角，不加速，乘上灵敏度。
final class Gestures {
    protocol Out: AnyObject {
        /// 视图坐标 → 远端归一化坐标（0..1）；还没有画面时返回 nil
        func toRemote(_ p: CGPoint) -> CGPoint?
        /// 画面在视图里的大小（放大后变大）
        func contentSize() -> CGSize
        func move(_ nx: CGFloat, _ ny: CGFloat)
        /// 相对移动：移动了画面宽 / 高的多少
        func delta(_ nx: CGFloat, _ ny: CGFloat)
        func button(_ b: String, _ down: Bool)
        func wheel(_ dx: Int, _ dy: Int)
        func zoom(_ factor: CGFloat, _ focus: CGPoint)
        func pan(_ dx: CGFloat, _ dy: CGFloat)
        /// 触控板模式下指针动了：画面放大时跟着它走
        func follow()
        func haptic()
        func ripple(_ p: CGPoint)
        func toggleKeyboard()
        func touch(_ id: Int, _ phase: String, _ nx: CGFloat, _ ny: CGFloat)
    }

    enum Mode { case trackpad, touch, passthrough, multitouch }

    struct P { var id: Int; var x: CGFloat; var y: CGFloat; var pt: CGPoint { CGPoint(x: x, y: y) } }

    weak var out: Out?
    var mode = Mode.trackpad
    var relative = false
    var lookGain: CGFloat?
    let slop: CGFloat

    private(set) var cursorX: CGFloat = 0.5
    private(set) var cursorY: CGFloat = 0.5

    var pressing: Bool { dragging }

    init(slop: CGFloat = 8) { self.slop = slop }

    func setCursor(_ x: CGFloat, _ y: CGFloat) {
        cursorX = min(max(x, 0), 1)
        cursorY = min(max(y, 0), 1)
    }

    private enum Kind { case none, one, two, many, done }
    private var kind = Kind.none
    private var startX: CGFloat = 0, startY: CGFloat = 0, startT: Double = 0
    private var lastX: CGFloat = 0, lastY: CGFloat = 0, lastT: Double = 0
    private var moved = false, longFired = false, dragging = false, looking = false, doubleTapDrag = false
    private var longTimer: DispatchWorkItem?
    private var pendingDown = false
    private var downTimer: DispatchWorkItem?
    private var twoStartT: Double = 0, twoStartSpan: CGFloat = 0, twoStartCx: CGFloat = 0, twoStartCy: CGFloat = 0
    private var twoLastSpan: CGFloat = 0, twoLastCx: CGFloat = 0, twoLastCy: CGFloat = 0
    private var twoKind = 0
    private var twoMoved = false
    private var maxFingers = 0
    private var wheelAccX: CGFloat = 0, wheelAccY: CGFloat = 0
    private var velX: CGFloat = 0, velY: CGFloat = 0
    private var flingTimer: DispatchWorkItem?
    private var touchIds: [Int: Int] = [:]
    private var touchPos: [Int: CGPoint] = [:]
    private var lastTapT: Double = -10_000, lastTapX: CGFloat = 0, lastTapY: CGFloat = 0

    static let longPressMs = 450.0, tapMs = 350.0, doubleTapMs = 300.0, twoTapMs = 300.0, threeTapMs = 400.0, passthroughDelayMs = 60.0
    /// 双指滚动：每点多少滚轮单位（120 = 一格，约 13 点一格，和 Android 上约 40 像素一格差不多）
    static let wheelPerPx: CGFloat = 9
    private static let frameMs: CGFloat = 16, flingMin: CGFloat = 0.6, flingStop: CGFloat = 0.05, flingDecay: CGFloat = 0.93

    /// 指针加速：慢慢移动时精细（0.7×），快速划过时更远（最多 2.4×）
    static func accel(_ pxPerMs: CGFloat) -> CGFloat { min(2.4, max(0.7, 0.7 + (pxPerMs - 0.2) * 0.9)) }

    private func after(_ ms: Double, _ f: @escaping () -> Void) -> DispatchWorkItem {
        let w = DispatchWorkItem(block: f)
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: w)
        return w
    }

    private var turning: Bool { relative && lookGain != nil }

    // ───────────── 事件 ─────────────

    func down(_ p: P, _ t: Double) {
        stopFling()
        guard let out else { return }
        if mode == .multitouch {
            kind = .many
            touchIds.removeAll()
            touchPos.removeAll()
            touchDown(p)
            out.ripple(p.pt)
            return
        }
        kind = .one
        maxFingers = 1
        startX = p.x; startY = p.y; startT = t
        lastX = p.x; lastY = p.y; lastT = t
        moved = false; longFired = false; dragging = false; looking = false; doubleTapDrag = false
        switch mode {
        case .multitouch: break
        case .trackpad:
            doubleTapDrag = t - lastTapT < Self.doubleTapMs && hypot(p.x - lastTapX, p.y - lastTapY) < slop * 4
            if !doubleTapDrag { longTimer = after(Self.longPressMs) { [weak self] in self?.onLongPress() } }
        case .touch:
            if !relative, let r = out.toRemote(p.pt) {
                setCursor(r.x, r.y)
                out.move(cursorX, cursorY)
            }
            longTimer = after(Self.longPressMs) { [weak self] in self?.onLongPress() }
        case .passthrough:
            guard let r = out.toRemote(p.pt) else { return }
            setCursor(r.x, r.y)
            pendingDown = true
            downTimer = after(Self.passthroughDelayMs) { [weak self] in self?.commitDown() }
        }
    }

    private func commitDown() {
        guard pendingDown, kind == .one, let out else { return }
        pendingDown = false
        guard let r = out.toRemote(CGPoint(x: startX, y: startY)) else { return }
        out.move(r.x, r.y)
        out.button("left", true)
        dragging = true
        if lastX != startX || lastY != startY, let r2 = out.toRemote(CGPoint(x: lastX, y: lastY)) { out.move(r2.x, r2.y) }
    }

    private func onLongPress() {
        longTimer = nil
        guard kind == .one, !moved, !turning, let out else { return }
        longFired = true
        out.haptic()
        switch mode {
        case .trackpad: click("right")
        case .touch:
            out.ripple(CGPoint(x: startX, y: startY))
            click("right")
        default: break
        }
    }

    private func click(_ b: String) {
        guard let out else { return }
        if !relative { out.move(cursorX, cursorY) }
        out.button(b, true)
        out.button(b, false)
    }

    func pointerDown(_ p: P, _ ps: [P], _ t: Double) {
        if mode == .multitouch {
            touchDown(p)
            return
        }
        longTimer?.cancel(); longTimer = nil
        maxFingers = max(maxFingers, ps.count)
        if ps.count >= 3 {
            endDrag()
            kind = .many
            return
        }
        if kind == .one {
            if pendingDown {
                pendingDown = false
                downTimer?.cancel()
            }
            endDrag()
            kind = .two
            twoStartT = t
            let (cx, cy, span) = centroid(ps)
            twoStartCx = cx; twoStartCy = cy; twoStartSpan = span
            twoLastCx = cx; twoLastCy = cy; twoLastSpan = span
            twoKind = mode == .passthrough ? 2 : 0
            twoMoved = moved
            wheelAccX = 0; wheelAccY = 0; velX = 0; velY = 0
        }
    }

    func move(_ ps: [P], _ t: Double) {
        guard let out else { return }
        if mode == .multitouch {
            for p in ps {
                guard let id = touchIds[p.id], touchPos[p.id] != p.pt else { continue }
                touchPos[p.id] = p.pt
                if let r = out.toRemote(p.pt) { out.touch(id, "move", r.x, r.y) }
            }
            return
        }
        switch kind {
        case .one: if let p = ps.first { moveOne(p, t) }
        case .two: if ps.count >= 2 { moveTwo(ps, t) }
        default: break
        }
    }

    private func moveOne(_ p: P, _ t: Double) {
        guard let out else { return }
        let dx = p.x - lastX, dy = p.y - lastY
        let dt = max(1, t - lastT)
        if !moved && hypot(p.x - startX, p.y - startY) > slop {
            moved = true
            longTimer?.cancel(); longTimer = nil
            switch mode {
            case .trackpad:
                if doubleTapDrag {
                    out.haptic()
                    if !relative { out.move(cursorX, cursorY) }
                    out.button("left", true)
                    dragging = true
                }
            case .touch:
                if !longFired {
                    if relative && lookGain != nil {
                        looking = true
                    } else {
                        if !relative, let r = out.toRemote(CGPoint(x: startX, y: startY)) { out.move(r.x, r.y) }
                        out.button("left", true)
                        dragging = true
                    }
                }
            case .passthrough:
                if pendingDown {
                    downTimer?.cancel()
                    commitDown()
                }
            case .multitouch: break
            }
        }
        lastX = p.x; lastY = p.y; lastT = t
        if !moved && mode != .passthrough { return }
        switch mode {
        case .trackpad:
            let size = out.contentSize()
            guard size.width > 0, size.height > 0 else { return }
            let gain = Self.accel(hypot(dx, dy) / CGFloat(dt))
            if relative {
                let g = lookGain ?? gain
                out.delta(dx / size.width * g, dy / size.height * g)
                return
            }
            setCursor(cursorX + dx / size.width * gain, cursorY + dy / size.height * gain)
            out.move(cursorX, cursorY)
            out.follow()
        case .touch:
            if dragging || looking {
                if relative {
                    let size = out.contentSize()
                    let g = lookGain ?? 1
                    if size.width > 0, size.height > 0 { out.delta(dx / size.width * g, dy / size.height * g) }
                } else if dragging, let r = out.toRemote(p.pt) {
                    setCursor(r.x, r.y)
                    out.move(cursorX, cursorY)
                }
            }
        case .passthrough:
            guard let r = out.toRemote(p.pt) else { return }
            setCursor(r.x, r.y)
            if dragging { out.move(cursorX, cursorY) }
        case .multitouch: break
        }
    }

    private func moveTwo(_ ps: [P], _ t: Double) {
        guard let out else { return }
        let (cx, cy, span) = centroid(ps)
        if twoKind == 0 {
            if abs(span - twoStartSpan) > slop * 2.5 {
                twoKind = 2; twoMoved = true
            } else if hypot(cx - twoStartCx, cy - twoStartCy) > slop {
                twoKind = 1; twoMoved = true
            }
        }
        let dx = cx - twoLastCx, dy = cy - twoLastCy
        let dt = CGFloat(max(1, t - lastT))
        switch twoKind {
        case 1:
            wheelAccY += dy * Self.wheelPerPx
            wheelAccX -= dx * Self.wheelPerPx
            flushWheel()
            velX = 0.6 * velX + 0.4 * (dx / dt)
            velY = 0.6 * velY + 0.4 * (dy / dt)
        case 2:
            if twoLastSpan > 0, span > 0 { out.zoom(span / twoLastSpan, CGPoint(x: cx, y: cy)) }
            out.pan(dx, dy)
        default: break
        }
        twoLastCx = cx; twoLastCy = cy; twoLastSpan = span
        lastT = t
    }

    private func flushWheel() {
        let ix = Int(wheelAccX), iy = Int(wheelAccY)
        if ix != 0 || iy != 0 {
            out?.wheel(ix, iy)
            wheelAccX -= CGFloat(ix)
            wheelAccY -= CGFloat(iy)
        }
    }

    func pointerUp(_ p: P, remaining: Int, _ t: Double) {
        guard let out else { return }
        if mode == .multitouch {
            touchUp(p, "up")
            return
        }
        if kind == .two && remaining == 1 {
            let tap = !twoMoved && maxFingers == 2 && t - twoStartT < Self.twoTapMs
            if tap {
                out.haptic()
                if mode == .touch, let r = out.toRemote(CGPoint(x: twoStartCx, y: twoStartCy)) { setCursor(r.x, r.y) }
                if mode != .passthrough { click("right") }
            } else if twoKind == 1 {
                startFling()
            }
            kind = .done
        } else if kind == .many && remaining == 2 {
            if maxFingers == 3 && t - startT < Self.threeTapMs { out.toggleKeyboard() }
            kind = .done
        }
    }

    func up(_ p: P, _ t: Double) {
        guard let out else { return }
        if mode == .multitouch {
            touchUp(p, "up")
            for (id, pos) in touchPos { touchUp(P(id: id, x: pos.x, y: pos.y), "cancel") }
            kind = .none
            return
        }
        longTimer?.cancel(); longTimer = nil
        if kind == .one {
            if p.x != lastX || p.y != lastY { moveOne(p, t) }
            switch mode {
            case .trackpad:
                if dragging {
                    out.button("left", false)
                } else if !moved && !longFired && t - startT < Self.tapMs {
                    click("left")
                    lastTapT = t; lastTapX = p.x; lastTapY = p.y
                }
            case .touch:
                if dragging {
                    out.button("left", false)
                } else if !longFired && !looking && !(turning && t - startT >= Self.tapMs) {
                    out.ripple(CGPoint(x: startX, y: startY))
                    click("left")
                }
            case .passthrough:
                if pendingDown {
                    pendingDown = false
                    downTimer?.cancel()
                    out.ripple(CGPoint(x: startX, y: startY))
                    if let r = out.toRemote(CGPoint(x: startX, y: startY)) { out.move(r.x, r.y) }
                    out.button("left", true)
                    if let r = out.toRemote(p.pt) { out.move(r.x, r.y) }
                    out.button("left", false)
                } else if dragging {
                    if let r = out.toRemote(p.pt) { out.move(r.x, r.y) }
                    out.button("left", false)
                }
            case .multitouch: break
            }
        }
        dragging = false
        looking = false
        kind = .none
    }

    func cancel() {
        looking = false
        for (id, pos) in touchPos { touchUp(P(id: id, x: pos.x, y: pos.y), "cancel") }
        longTimer?.cancel()
        downTimer?.cancel()
        pendingDown = false
        endDrag()
        kind = .none
    }

    private func touchDown(_ p: P) {
        guard touchIds[p.id] == nil, let slot = (0..<10).first(where: { !touchIds.values.contains($0) }),
              let r = out?.toRemote(p.pt) else { return }
        touchIds[p.id] = slot
        touchPos[p.id] = p.pt
        out?.touch(slot, "down", r.x, r.y)
    }

    private func touchUp(_ p: P, _ phase: String) {
        guard let slot = touchIds.removeValue(forKey: p.id) else { return }
        touchPos[p.id] = nil
        let r = out?.toRemote(p.pt) ?? .zero
        out?.touch(slot, phase, r.x, r.y)
    }

    private func endDrag() {
        if dragging {
            out?.button("left", false)
            dragging = false
        }
    }

    private func startFling() {
        guard hypot(velX, velY) >= Self.flingMin else { return }
        func tick() {
            velX *= Self.flingDecay
            velY *= Self.flingDecay
            if hypot(velX, velY) < Self.flingStop {
                flingTimer = nil
                return
            }
            wheelAccY += velY * Self.frameMs * Self.wheelPerPx
            wheelAccX -= velX * Self.frameMs * Self.wheelPerPx
            flushWheel()
            flingTimer = after(Double(Self.frameMs)) { tick() }
        }
        flingTimer = after(Double(Self.frameMs)) { tick() }
    }

    func stopFling() {
        flingTimer?.cancel()
        flingTimer = nil
    }

    private func centroid(_ ps: [P]) -> (CGFloat, CGFloat, CGFloat) {
        let a = ps[0], b = ps[1]
        return ((a.x + b.x) / 2, (a.y + b.y) / 2, hypot(a.x - b.x, a.y - b.y))
    }
}

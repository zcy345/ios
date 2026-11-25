import AVFoundation
import GameController
import Observation
import SwiftUI
import UIKit

/// 画面：AVSampleBufferDisplayLayer，大小就是画面显示的区域（放大、移动时改它的 frame）
final class VideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resize
        isUserInteractionEnabled = false
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 接收触摸的画布：把手指交给控制器
final class SessionCanvas: UIView {
    weak var controller: SessionController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { controller?.touches(t, e, .began) }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { controller?.touches(t, e, .moved) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { controller?.touches(t, e, .ended) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { controller?.touches(t, e, .cancelled) }
}

/// 软键盘的输入框（看不见）：输入法组字时等它组完再发；删除键在框是空的时候也收得到
final class KeyField: UITextField, UITextFieldDelegate {
    var onText: (String) -> Void = { _ in }
    var onBackspace: () -> Void = {}
    var onEnter: () -> Void = {}
    var onComposing: (String) -> Void = { _ in }
    var onPresses: (Set<UIPress>, Bool) -> Bool = { _, _ in false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .default
        returnKeyType = .default
        keyboardAppearance = .dark
        textColor = .clear
        tintColor = .clear
        delegate = self
        addTarget(self, action: #selector(changed), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        if markedTextRange != nil {
            onComposing(text ?? "")
            return
        }
        onComposing("")
        if let t = text, !t.isEmpty {
            onText(t)
            text = ""
        }
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty { onBackspace() } else { super.deleteBackward() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if markedTextRange == nil { onEnter() }
        return false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !onPresses(presses, true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !onPresses(presses, false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !onPresses(presses, false) { super.pressesCancelled(presses, with: event) }
    }
}

/// 软键盘上面那一排特殊键的状态：修饰键是“粘滞”的——点一下只对下一个键有效，再点一下锁定，再点取消
@Observable
final class KeyboardState {
    enum Sticky { case off, once, locked }
    static let mods = ["ControlLeft", "AltLeft", "ShiftLeft", "MetaLeft"]
    var mods: [String: Sticky] = [:]
    var composing = ""
    @ObservationIgnored var send: ([JSON]) -> Void = { _ in }

    func state(_ m: String) -> Sticky { mods[m] ?? .off }

    func toggle(_ m: String) {
        switch state(m) {
        case .off: mods[m] = .once
        case .once: mods[m] = .locked
        case .locked: mods[m] = .off
        }
    }

    private var active: [String] { Self.mods.filter { state($0) != .off } }

    private func consumeOnce() {
        for m in Self.mods where state(m) == .once { mods[m] = .off }
    }

    /// 按一个键（带上按着的修饰键）
    func press(_ code: String, shift: Bool = false) {
        var chord = active
        if shift && !chord.contains("ShiftLeft") { chord.append("ShiftLeft") }
        send(Input.chord(chord + [code]))
        consumeOnce()
    }

    func chord(_ codes: [String]) { send(Input.chord(codes)) }

    /// 软键盘打的字：没有修饰键时按文字发（输入法打的中文也行），有修饰键时按键发（Ctrl + C 这样的）
    func text(_ s: String) {
        let mods = active
        if mods.isEmpty || mods == ["ShiftLeft"] && s.count > 1 {
            send([Input.text(s)])
            consumeOnce()
            return
        }
        for ch in s {
            if let (code, shift) = KeyMap.forChar(ch) { press(code, shift: shift) } else { send([Input.text(String(ch))]) }
        }
    }
}

/// 远程画面：画面、手势、键盘、鼠标、游戏按键，菜单和提示叠在上面
final class SessionController: UIViewController, Gestures.Out, UIPointerInteractionDelegate, UIGestureRecognizerDelegate,
    UIAdaptivePresentationControllerDelegate {
    let app: AppModel
    let session: RemoteSession
    private let canvas = SessionCanvas()
    private let video = VideoView()
    private let cursorLayer = CALayer()
    private let gestures = Gestures(slop: 8)
    private let keyField = KeyField()
    private let keyboard = KeyboardState()
    private let game = GameLayerView()
    private let menuButton = FloatingMenuButton()
    private var overlayHost: UIHostingController<SessionOverlay>!
    private var bannerHost: UIHostingController<SessionBanner>!
    private var navHost: UIHostingController<NavKeysBar>?
    private var accessory: UIHostingController<KeyBar>!

    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    private var keyboardHeight: CGFloat = 0
    private var touchIds: [ObjectIdentifier: Int] = [:]
    private var nextTouchId = 0
    private var activeTouches: [ObjectIdentifier: UITouch] = [:]
    private var deltaRemainder = CGPoint.zero
    private var pressed: Set<String> = []
    private var escDownAt: Double?
    private var hoverPoint: CGPoint?
    private var lockSuspended = false
    private var mice: [GCMouse] = []
    private var mouseButtonDown: String?
    private var orientationPortrait: Bool?
    private var manualOrientation = false
    private var shownFrames = false
    let ui = SessionUIState()

    init(app: AppModel, session: RemoteSession) {
        self.app = app
        self.session = session
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone, let p = orientationPortrait else { return .all }
        return p ? .portrait : .landscape
    }

    /// 被控端的光标隐藏了（游戏里转视角）或者锁定了鼠标：发相对移动
    private var relative: Bool {
        guard !session.os.isPhone else { return false }
        if session.mouseLock { return true }
        return !session.cursor.visible && !session.cursor.inFrame && !lockSuspended
    }

    override var prefersPointerLocked: Bool { relative && !mice.isEmpty }

    // ───────────────────────────── 视图 ─────────────────────────────

    override func loadView() {
        canvas.controller = self
        view = canvas
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(video)
        cursorLayer.zPosition = 10
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .nearest
        view.layer.addSublayer(cursorLayer)

        game.os = session.os
        game.output.send = { [weak self] e in self?.session.input(e) }
        game.output.look = { [weak self] dx, dy in self?.look(dx, dy) }
        view.addSubview(game)

        keyField.frame = CGRect(x: -100, y: -100, width: 10, height: 10)
        keyboard.send = { [weak self] e in self?.session.input(e) }
        keyField.onText = { [weak self] t in self?.keyboard.text(t) }
        keyField.onBackspace = { [weak self] in self?.keyboard.press("Backspace") }
        keyField.onEnter = { [weak self] in self?.keyboard.press("Enter") }
        keyField.onComposing = { [weak self] s in self?.keyboard.composing = s }
        keyField.onPresses = { [weak self] p, down in self?.hardwareKeys(p, down) ?? false }
        accessory = UIHostingController(rootView: KeyBar(state: keyboard, os: session.os, hide: { [weak self] in self?.setKeyboard(false) }))
        accessory.view.backgroundColor = .clear
        accessory.sizingOptions = [.intrinsicContentSize]
        accessory.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 54)
        accessory.view.autoresizingMask = [.flexibleWidth]
        keyField.inputAccessoryView = accessory.view
        view.addSubview(keyField)

        menuButton.onTap = { [weak self] in self?.openMenu() }
        view.addSubview(menuButton)

        bannerHost = UIHostingController(rootView: SessionBanner(session: session, app: app))
        bannerHost.view.backgroundColor = .clear
        bannerHost.sizingOptions = [.intrinsicContentSize]
        addChild(bannerHost)
        view.addSubview(bannerHost.view)
        bannerHost.didMove(toParent: self)

        overlayHost = UIHostingController(rootView: SessionOverlay(session: session, ui: ui, close: { [weak self] in self?.disconnect(confirm: false) }))
        overlayHost.view.backgroundColor = .clear
        addChild(overlayHost)
        view.addSubview(overlayHost.view)
        overlayHost.didMove(toParent: self)

        gestures.out = self
        session.decoder.onFirstFrame = { [weak self] in DispatchQueue.main.async { self?.ui.hasVideo = true; self?.updateOverlay() } }
        session.onCursor = { [weak self] c in self?.cursorChanged(c) }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        view.addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        view.addGestureRecognizer(scroll)
        view.addInteraction(UIPointerInteraction(delegate: self))

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mouseConnected(_:)), name: .GCMouseDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mouseDisconnected(_:)), name: .GCMouseDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        GCMouse.mice().forEach(setupMouse)

        observe { [weak self] in self?.sessionChanged() }
        observe { [weak self] in self?.gameChanged() }
        cursorChanged(session.cursor)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session.decoder.setLayer(video.displayLayer)
        becomeFirstResponder()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "AirhandNoTips") { app.settings.tipsShown = true }
        if UserDefaults.standard.bool(forKey: "AirhandSelfTest") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.selfTest() } }
        if UserDefaults.standard.bool(forKey: "AirhandOpenMenu") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.openMenu() } }
        if UserDefaults.standard.bool(forKey: "AirhandGame") { app.games.setEnabled(session.code, true) }
        if UserDefaults.standard.bool(forKey: "AirhandKeyboard") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.setKeyboard(true) } }
        if UserDefaults.standard.bool(forKey: "AirhandEditGame") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if let l = self.app.games.active(self.session.code) { self.editGame(l) } }
        }
        #endif
        if !app.settings.tipsShown {
            app.settings.tipsShown = true
            showTips()
        }
    }

    #if DEBUG
    /// 开发用（-AirhandSelfTest 1）：模拟一串手势、键盘，看被控端收到的输入对不对
    private func selfTest() {
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        var t = CACurrentMediaTime() * 1000
        func p(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> Gestures.P { Gestures.P(id: id, x: x, y: y) }
        Log.info("selftest: slide")
        gestures.down(p(1, c.x, c.y), t)
        for i in 1...10 { t += 16; gestures.move([p(1, c.x + CGFloat(i) * 12, c.y + CGFloat(i) * 4)], t) }
        t += 16; gestures.up(p(1, c.x + 120, c.y + 40), t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Log.info("selftest: tap")
            var t = CACurrentMediaTime() * 1000
            self.gestures.down(p(2, c.x, c.y), t)
            t += 80; self.gestures.up(p(2, c.x, c.y), t)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            Log.info("selftest: two-finger scroll")
            var t = CACurrentMediaTime() * 1000
            self.gestures.down(p(3, c.x - 40, c.y), t)
            t += 10; self.gestures.pointerDown(p(4, c.x + 40, c.y), [p(3, c.x - 40, c.y), p(4, c.x + 40, c.y)], t)
            for i in 1...8 { t += 16; self.gestures.move([p(3, c.x - 40, c.y + CGFloat(i) * 10), p(4, c.x + 40, c.y + CGFloat(i) * 10)], t) }
            t += 16; self.gestures.pointerUp(p(4, c.x + 40, c.y + 80), remaining: 1, t)
            t += 16; self.gestures.up(p(3, c.x - 40, c.y + 80), t)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            Log.info("selftest: keyboard")
            self.keyboard.text("hello 你好")
            self.keyboard.toggle("ControlLeft")
            self.keyboard.text("c")
            self.keyboard.press("Enter")
        }
    }
    #endif

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        game.releaseAll()
        releaseKeys()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.decoder.setLayer(nil)
    }

    /// 观察 RemoteSession / AppModel 的变化（UIKit 里用 Observation）
    private func observe(_ apply: @escaping () -> Void) {
        withObservationTracking(apply) { [weak self] in
            DispatchQueue.main.async { if self != nil { self?.observe(apply) } }
        }
    }

    private func sessionChanged() {
        _ = session.phase
        _ = session.videoSize
        _ = session.mouseLock
        _ = session.hello
        _ = app.settings.navKeys
        updateMode()
        updateOrientation()
        updateNavBar()
        updateOverlay()
        view.setNeedsLayout()
        if session.phase != .live {
            game.releaseAll()
            releaseKeys()
        }
    }

    private func gameChanged() {
        let l = session.os.isPhone ? nil : app.games.active(session.code)
        game.apply(l)
        gestures.lookGain = l.map { CGFloat($0.lookSpeed) }
    }

    private func updateOverlay() {
        let live = session.phase == .live
        let hide = live && ui.hasVideo
        overlayHost.view.isHidden = hide
        menuButton.isHidden = !live
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        overlayHost.view.frame = b
        game.frame = availableRect()
        game.setNeedsLayout()
        menuButton.layoutIn(b.inset(by: view.safeAreaInsets))
        let bannerSize = bannerHost.view.intrinsicContentSize
        let w = min(b.width - 32, max(bannerSize.width, 10))
        bannerHost.view.frame = CGRect(x: (b.width - w) / 2, y: view.safeAreaInsets.top + 8, width: w, height: max(bannerSize.height, 0))
        if let nav = navHost {
            let h: CGFloat = 52 + view.safeAreaInsets.bottom
            nav.view.frame = CGRect(x: 0, y: b.height - h - keyboardHeight, width: b.width, height: h)
        }
        layoutVideo()
    }

    /// 画面能用的区域：去掉键盘和导航键
    private func availableRect() -> CGRect {
        var r = view.bounds
        r.size.height -= keyboardHeight
        if let nav = navHost, !nav.view.isHidden { r.size.height -= 52 + (keyboardHeight > 0 ? 0 : view.safeAreaInsets.bottom) }
        return r
    }

    /// 画面整个按比例放进可用区域（适应屏幕）
    private func fittedRect() -> CGRect {
        let avail = availableRect()
        guard let vs = session.videoSize, vs.width > 0, vs.height > 0 else { return avail }
        let s = min(avail.width / vs.width, avail.height / vs.height)
        let size = CGSize(width: vs.width * s, height: vs.height * s)
        return CGRect(x: avail.midX - size.width / 2, y: avail.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 画面现在显示在哪里（放大、移动之后）
    private var contentRect: CGRect {
        let fit = fittedRect()
        let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
        return CGRect(x: fit.midX - size.width / 2 + offset.x, y: fit.midY - size.height / 2 + offset.y, width: size.width, height: size.height)
    }

    /// 放大后画面不留空边：能铺满的方向上不让移出去
    private func clampOffset() {
        let avail = availableRect()
        let fit = fittedRect()
        let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
        func clamp(_ o: CGFloat, _ content: CGFloat, _ space: CGFloat, _ fitMid: CGFloat, _ availMin: CGFloat) -> CGFloat {
            if content <= space { return (availMin + space / 2) - fitMid }
            let minO = availMin + space - (fitMid + content / 2)
            let maxO = availMin - (fitMid - content / 2)
            return min(max(o, minO), maxO)
        }
        offset.x = clamp(offset.x, size.width, avail.width, fit.midX, avail.minX)
        offset.y = clamp(offset.y, size.height, avail.height, fit.midY, avail.minY)
    }

    private func layoutVideo() {
        clampOffset()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = contentRect.integral
        CATransaction.commit()
        updateCursorLayer()
    }

    // ───────────────────────────── 方向、模式 ─────────────────────────────

    /// 手机上跟着对方的画面横 / 竖（菜单里可以转）
    private func updateOrientation() {
        guard UIDevice.current.userInterfaceIdiom == .phone, !manualOrientation else { return }
        if let vs = session.videoSize, vs.width > 0, vs.height > 0 {
            // 对方转了屏（手机），这边也跟着转
            apply(vs.height > vs.width)
        } else if orientationPortrait == nil, session.os.isPhone {
            apply(true)
        }
    }

    private func apply(_ portrait: Bool) {
        if orientationPortrait == portrait { return }
        orientationPortrait = portrait
        AppDelegate.orientationLock = portrait ? .portrait : .landscape
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: portrait ? .portrait : .landscape)) { _ in }
    }

    /// 菜单里的“旋转画面”：之后不再跟着对方的画面自动转
    func rotate() {
        manualOrientation = true
        apply(!(orientationPortrait ?? (view.bounds.height > view.bounds.width)))
    }

    /// 操作方式：手机（能接收触摸就多点触摸，否则直通），电脑按设置（自动 = 触控板）或者菜单里的选择
    private func updateMode() {
        let os = session.os
        if os.isPhone {
            gestures.mode = (session.hello?.touch ?? false) ? .multitouch : .passthrough
        } else {
            let m = ui.mode ?? (app.settings.touchMode == "touch" ? "touch" : "trackpad")
            gestures.mode = m == "touch" ? .touch : .trackpad
        }
        gestures.relative = relative
        ui.effectiveMode = gestures.mode == .touch ? "touch" : (gestures.mode == .trackpad ? "trackpad" : "phone")
        setNeedsUpdateOfPrefersPointerLocked()
        updateCursorLayer()
    }

    func setMode(_ m: String) {
        ui.mode = m
        updateMode()
    }

    private func updateNavBar() {
        let show = session.os.isPhone && session.os != .ios && app.settings.navKeys
            && (session.hello?.actions.contains(.back) ?? false)
        if show, navHost == nil {
            let h = UIHostingController(rootView: NavKeysBar(action: { [weak self] a in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.session.system(a)
            }))
            h.view.backgroundColor = .clear
            addChild(h)
            view.addSubview(h.view)
            h.didMove(toParent: self)
            navHost = h
            view.bringSubviewToFront(menuButton)
            view.bringSubviewToFront(overlayHost.view)
        } else if !show, let h = navHost {
            h.willMove(toParent: nil)
            h.view.removeFromSuperview()
            h.removeFromParent()
            navHost = nil
        }
    }

    // ───────────────────────────── 光标 ─────────────────────────────

    private static let defaultCursor: CGImage = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 26))
        let img = r.image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 1, y: 1))
            p.addLine(to: CGPoint(x: 1, y: 21))
            p.addLine(to: CGPoint(x: 6, y: 16.5))
            p.addLine(to: CGPoint(x: 9.5, y: 24.5))
            p.addLine(to: CGPoint(x: 12.5, y: 23))
            p.addLine(to: CGPoint(x: 9, y: 15))
            p.addLine(to: CGPoint(x: 15.5, y: 15))
            p.close()
            UIColor.black.setFill()
            p.fill()
            UIColor.white.setStroke()
            p.lineWidth = 1.4
            p.stroke()
        }
        return img.cgImage!
    }()

    private func cursorChanged(_ c: CursorState) {
        let was = gestures.relative
        gestures.relative = relative
        if was != gestures.relative {
            if !gestures.relative { lockSuspended = false }
            setNeedsUpdateOfPrefersPointerLocked()
        }
        updateCursorLayer()
    }

    /// 本机画的光标：触控板模式在指针的位置，鼠标在鼠标的位置；对方隐藏了光标、相对移动时不画
    private func updateCursorLayer() {
        let c = session.cursor
        let mouse = hoverPoint != nil
        let show = session.phase == .live && !session.os.isPhone && !relative && c.visible
            && (gestures.mode == .trackpad || mouse) && (!c.inFrame || app.settings.localCursor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard show else {
            cursorLayer.isHidden = true
            return
        }
        let rect = contentRect
        let img: CGImage
        let size: CGSize
        let hot: CGPoint
        if let custom = c.image {
            // 光标图像是被控端显示器的像素：按画面显示的比例缩放（画面可能比对方的屏幕小）
            let d = session.displays.first { $0.index == session.currentDisplay }
            let srcW = CGFloat(d?.width ?? Int(session.videoSize?.width ?? CGFloat(custom.width)))
            let scale = max(0.5, min(rect.width / max(srcW, 1), 2.5))
            img = custom
            size = CGSize(width: CGFloat(custom.width) * scale, height: CGFloat(custom.height) * scale)
            hot = CGPoint(x: CGFloat(c.hotX) * scale, y: CGFloat(c.hotY) * scale)
        } else {
            img = Self.defaultCursor
            size = CGSize(width: 18, height: 26)
            hot = CGPoint(x: 1, y: 1)
        }
        let p = mouse ? hoverPoint! : CGPoint(x: rect.minX + rect.width * gestures.cursorX, y: rect.minY + rect.height * gestures.cursorY)
        cursorLayer.contents = img
        cursorLayer.frame = CGRect(x: p.x - hot.x, y: p.y - hot.y, width: size.width, height: size.height)
        cursorLayer.isHidden = false
    }

    // ───────────────────────────── 触摸 ─────────────────────────────

    func touches(_ set: Set<UITouch>, _ event: UIEvent?, _ phase: UITouch.Phase) {
        // 只能看的（对方是 iPhone / iPad）也照样处理手势：双指缩放本机的画面，发出去的输入在会话那里丢掉
        guard session.phase == .live else { return }
        var fingers: [UITouch] = []
        for t in set {
            if t.type == .indirectPointer {
                mouseTouch(t, event, phase)
            } else {
                fingers.append(t)
            }
        }
        guard !fingers.isEmpty else { return }
        let ms = (fingers.first?.timestamp ?? 0) * 1000
        func p(_ t: UITouch) -> Gestures.P {
            let id = touchIds[ObjectIdentifier(t)] ?? 0
            let l = t.location(in: view)
            return Gestures.P(id: id, x: l.x, y: l.y)
        }
        switch phase {
        case .began:
            for t in fingers {
                touchIds[ObjectIdentifier(t)] = nextTouchId
                nextTouchId += 1
                let first = activeTouches.isEmpty
                activeTouches[ObjectIdentifier(t)] = t
                if first {
                    gestures.down(p(t), ms)
                } else {
                    gestures.pointerDown(p(t), activeTouches.values.map(p), ms)
                }
            }
        case .moved:
            gestures.move(activeTouches.values.map(p), ms)
        case .ended:
            for t in fingers {
                activeTouches[ObjectIdentifier(t)] = nil
                let remaining = activeTouches.count
                if remaining == 0 { gestures.up(p(t), ms) } else { gestures.pointerUp(p(t), remaining: remaining, ms) }
                touchIds[ObjectIdentifier(t)] = nil
            }
        default:
            for t in fingers {
                activeTouches[ObjectIdentifier(t)] = nil
                touchIds[ObjectIdentifier(t)] = nil
            }
            if activeTouches.isEmpty { gestures.cancel() }
        }
        if activeTouches.isEmpty { touchIds.removeAll() }
    }

    // ── Gestures.Out ──

    func toRemote(_ p: CGPoint) -> CGPoint? {
        guard session.videoSize != nil else { return nil }
        let r = contentRect
        guard r.width > 0, r.height > 0 else { return nil }
        return CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
    }

    func contentSize() -> CGSize { contentRect.size }

    func move(_ nx: CGFloat, _ ny: CGFloat) {
        session.input([Input.move(Double(nx), Double(ny))], now: false)
        if hoverPoint == nil { updateCursorLayer() }
    }

    /// 相对移动：画面宽 / 高的比例 → 对方显示器的像素
    func delta(_ nx: CGFloat, _ ny: CGFloat) {
        let d = session.displays.first { $0.index == session.currentDisplay }
        let w = CGFloat(d?.width ?? Int(session.videoSize?.width ?? 1920))
        let h = CGFloat(d?.height ?? Int(session.videoSize?.height ?? 1080))
        sendDelta(nx * w, ny * h)
    }

    private func sendDelta(_ dx: CGFloat, _ dy: CGFloat) {
        deltaRemainder.x += dx
        deltaRemainder.y += dy
        let ix = Int(deltaRemainder.x.rounded(.towardZero)), iy = Int(deltaRemainder.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        deltaRemainder.x -= CGFloat(ix)
        deltaRemainder.y -= CGFloat(iy)
        session.input([Input.delta(ix, iy)], now: false)
    }

    /// 游戏按键上的拖动（点）→ 转视角
    private func look(_ dx: CGFloat, _ dy: CGFloat) {
        guard relative else { return }
        let size = contentRect.size
        guard size.width > 0, size.height > 0 else { return }
        let g = gestures.lookGain ?? 1
        delta(dx / size.width * g, dy / size.height * g)
    }

    func button(_ b: String, _ down: Bool) { session.input([Input.button(b, down)]) }
    func wheel(_ dx: Int, _ dy: Int) { session.input([Input.wheel(dx, dy)]) }

    func zoom(_ factor: CGFloat, _ focus: CGPoint) {
        let old = zoom
        zoom = min(max(zoom * factor, 1), 6)
        let f = zoom / old
        // 以手指为中心缩放
        let r = contentRect
        let cx = r.midX, cy = r.midY
        offset.x += (focus.x - cx) * (1 - f)
        offset.y += (focus.y - cy) * (1 - f)
        layoutVideo()
        zoomChanged()
    }

    func pan(_ dx: CGFloat, _ dy: CGFloat) {
        guard zoom > 1 else { return }
        offset.x += dx
        offset.y += dy
        layoutVideo()
    }

    /// 触控板模式：指针走到边上时画面跟着走
    func follow() {
        guard zoom > 1 else { updateCursorLayer(); return }
        let r = contentRect
        let avail = availableRect().insetBy(dx: 40, dy: 40)
        let p = CGPoint(x: r.minX + r.width * gestures.cursorX, y: r.minY + r.height * gestures.cursorY)
        if p.x < avail.minX { offset.x += avail.minX - p.x }
        if p.x > avail.maxX { offset.x -= p.x - avail.maxX }
        if p.y < avail.minY { offset.y += avail.minY - p.y }
        if p.y > avail.maxY { offset.y -= p.y - avail.maxY }
        layoutVideo()
    }

    private func zoomChanged() {
        let r = contentRect
        let s = view.window?.screen.scale ?? UIScreen.main.scale
        session.setZoom(zoom > 1.05, shown: CGSize(width: r.width * s, height: r.height * s))
    }

    func fitScreen() {
        zoom = 1
        offset = .zero
        layoutVideo()
        zoomChanged()
    }

    func haptic() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

    func ripple(_ p: CGPoint) {
        let l = CAShapeLayer()
        l.path = UIBezierPath(ovalIn: CGRect(x: -22, y: -22, width: 44, height: 44)).cgPath
        l.position = p
        l.fillColor = UIColor(white: 1, alpha: 0.28).cgColor
        l.strokeColor = UIColor(white: 1, alpha: 0.6).cgColor
        l.lineWidth = 1.5
        l.zPosition = 20
        view.layer.addSublayer(l)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.5
        scale.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = 0.35
        g.isRemovedOnCompletion = false
        g.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: nil)
        CATransaction.commit()
    }

    func toggleKeyboard() { setKeyboard(!keyField.isFirstResponder) }

    func touch(_ id: Int, _ phase: String, _ nx: CGFloat, _ ny: CGFloat) {
        session.input([Input.touch(id, phase, Double(nx), Double(ny))], now: phase != "move")
    }

    // ───────────────────────────── 键盘 ─────────────────────────────

    func setKeyboard(_ on: Bool) {
        if on {
            game.releaseAll()
            keyField.becomeFirstResponder()
        } else {
            keyField.resignFirstResponder()
            becomeFirstResponder()
        }
    }

    @objc private func keyboardFrame(_ n: Notification) {
        var h: CGFloat = 0
        if n.name != UIResponder.keyboardWillHideNotification, let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let local = view.convert(f, from: nil)
            h = max(0, view.bounds.maxY - local.minY)
        }
        if h == keyboardHeight { return }
        keyboardHeight = h
        // 打字的时候游戏按键收起来（画面缩到键盘上面了，按钮挤在一起也按不准）
        game.isHidden = h > 0
        UIView.animate(withDuration: 0.25) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !hardwareKeys(presses, true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !hardwareKeys(presses, false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !hardwareKeys(presses, false) { super.pressesCancelled(presses, with: event) }
    }

    /// 外接键盘：按物理键发（游戏要按下 / 松开）；长按 Esc 放开锁定的鼠标
    private func hardwareKeys(_ presses: Set<UIPress>, _ down: Bool) -> Bool {
        guard session.phase == .live, !session.viewOnly else { return false }
        var handled = false
        for p in presses {
            guard let key = p.key, let code = KeyMap.code(hid: key.keyCode.rawValue) else { continue }
            handled = true
            if down {
                if pressed.contains(code) { continue }
                pressed.insert(code)
            } else {
                guard pressed.remove(code) != nil else { continue }
            }
            session.input([Input.key(code, down)])
            if code == "Escape" {
                if down {
                    escDownAt = CACurrentMediaTime()
                } else if let t = escDownAt, CACurrentMediaTime() - t > 0.6, relative {
                    releasePointer()
                }
            }
        }
        return handled
    }

    private func releaseKeys() {
        if !pressed.isEmpty {
            session.input(pressed.map { Input.key($0, false) })
            pressed.removeAll()
        }
    }

    private func releasePointer() {
        session.mouseLock = false
        lockSuspended = true
        gestures.relative = relative
        setNeedsUpdateOfPrefersPointerLocked()
        updateCursorLayer()
    }

    @objc private func resignActive() {
        game.releaseAll()
        releaseKeys()
        session.input([Input.releaseAll()])
    }

    // ───────────────────────────── 鼠标 ─────────────────────────────

    @objc private func mouseConnected(_ n: Notification) {
        if let m = n.object as? GCMouse { setupMouse(m) }
    }

    @objc private func mouseDisconnected(_ n: Notification) {
        mice.removeAll { $0 === n.object as? GCMouse }
        setNeedsUpdateOfPrefersPointerLocked()
    }

    private func setupMouse(_ m: GCMouse) {
        guard !mice.contains(where: { $0 === m }), let input = m.mouseInput else { return }
        mice.append(m)
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self, self.session.phase == .live, self.relative else { return }
            self.sendDelta(CGFloat(dx), CGFloat(-dy))
        }
        let buttons: [(GCControllerButtonInput?, String)] = [
            (input.leftButton, "left"), (input.rightButton, "right"), (input.middleButton, "middle"),
            (input.auxiliaryButtons?.first, "back"), (input.auxiliaryButtons?.dropFirst().first, "forward"),
        ]
        for (b, name) in buttons {
            b?.pressedChangedHandler = { [weak self] _, _, down in
                guard let self, self.session.phase == .live, !self.session.viewOnly else { return }
                if down { self.lockSuspended = false; self.setNeedsUpdateOfPrefersPointerLocked() }
                if !self.relative, let p = self.hoverPoint, let r = self.toRemote(p) { self.session.input([Input.move(r.x, r.y)]) }
                self.session.input([Input.button(name, down)])
            }
        }
        setNeedsUpdateOfPrefersPointerLocked()
    }

    /// 没有 GameController 的鼠标时（例如模拟器）：鼠标按下也是一种触摸
    private func mouseTouch(_ t: UITouch, _ e: UIEvent?, _ phase: UITouch.Phase) {
        let p = t.location(in: view)
        hoverPoint = p
        if !relative, let r = toRemote(p) { session.input([Input.move(r.x, r.y)], now: phase != .moved) }
        updateCursorLayer()
        guard mice.isEmpty, !session.viewOnly else { return }
        switch phase {
        case .began:
            let b = (e?.buttonMask.contains(.secondary) ?? false) ? "right" : "left"
            mouseButtonDown = b
            session.input([Input.button(b, true)])
        case .ended, .cancelled:
            if let b = mouseButtonDown { session.input([Input.button(b, false)]) }
            mouseButtonDown = nil
        default: break
        }
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let p = g.location(in: view)
            hoverPoint = p
            if session.phase == .live, !relative, !session.viewOnly, let r = toRemote(p) {
                session.input([Input.move(r.x, r.y)], now: false)
            }
        default:
            hoverPoint = nil
        }
        updateCursorLayer()
    }

    @objc private func scroll(_ g: UIPanGestureRecognizer) {
        guard session.phase == .live, !session.viewOnly else { return }
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        let dx = Int(-t.x * Gestures.wheelPerPx), dy = Int(t.y * Gestures.wheelPerPx)
        if dx != 0 || dy != 0 { session.input([Input.wheel(dx, dy)], now: false) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        session.phase == .live && !session.os.isPhone ? .hidden() : nil
    }

    // ───────────────────────────── 菜单 ─────────────────────────────

    private func openMenu() {
        game.releaseAll()
        releaseKeys()
        let menu = SessionMenu(app: app, session: session, ui: ui, actions: SessionMenuActions(
            keyboard: { [weak self] in self?.dismissThen { self?.setKeyboard(true) } },
            fit: { [weak self] in self?.dismissThen { self?.fitScreen() } },
            rotate: UIDevice.current.userInterfaceIdiom == .phone ? { [weak self] in self?.dismissThen { self?.rotate() } } : nil,
            files: { [weak self] in self?.dismissThen { self?.pickFiles() } },
            mode: { [weak self] m in self?.setMode(m) },
            editGame: { [weak self] l in self?.dismissThen { self?.editGame(l) } },
            tips: { [weak self] in self?.dismissThen { self?.showTips() } },
            disconnect: { [weak self] in self?.dismissThen { self?.disconnect(confirm: true) } },
            minimize: { [weak self] in self?.dismissThen { self?.app.showingSession = false } }
        ))
        let host = UIHostingController(rootView: menu)
        host.view.backgroundColor = UIColor(Theme.bg)
        host.overrideUserInterfaceStyle = .dark
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.preferredCornerRadius = 24
        }
        host.presentationController?.delegate = self
        present(host, animated: true)
    }

    /// 菜单被拖下去关掉了：键盘焦点回到画面（外接键盘接着能用）
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if !keyField.isFirstResponder { becomeFirstResponder() }
    }

    private func dismissThen(_ f: @escaping () -> Void) {
        if let p = presentedViewController {
            p.dismiss(animated: true) { [weak self] in
                if self?.keyField.isFirstResponder == false { self?.becomeFirstResponder() }
                f()
            }
        } else {
            f()
        }
    }

    private func pickFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = filePickerDelegate
        present(picker, animated: true)
    }

    private lazy var filePickerDelegate = FilePickerDelegate { [weak self] urls in
        guard let self else { return }
        ClipFiles.offer(urls, to: self.session)
    }

    private func editGame(_ layout: GameLayout) {
        game.isHidden = true
        let editor = GameEditor(app: app, original: layout, os: session.os, done: { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true)
            self.game.isHidden = self.keyboardHeight > 0
        })
        let host = UIHostingController(rootView: editor)
        host.modalPresentationStyle = .overFullScreen
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = .dark
        present(host, animated: true)
    }

    private func showTips() {
        let mode: Gestures.Mode = gestures.mode
        let host = UIHostingController(rootView: GestureTips(mode: mode, os: session.os))
        host.overrideUserInterfaceStyle = .dark
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    func disconnect(confirm: Bool) {
        guard confirm, session.phase == .live else {
            close()
            return
        }
        let a = UIAlertController(title: L.t("disconnect_title"), message: L.t("disconnect_text", session.hostName), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L.t("cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L.t("disconnect"), style: .destructive) { [weak self] _ in self?.close() })
        present(a, animated: true)
    }

    private func close() {
        game.releaseAll()
        releaseKeys()
        app.closeSession()
    }
}

/// 远程画面上界面层的状态（SwiftUI 部分观察）
@Observable
final class SessionUIState {
    var hasVideo = false
    /// 菜单里选的操作方式（电脑）：trackpad / touch；nil = 按设置
    var mode: String?
    var effectiveMode = "trackpad"
}

final class FilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    let picked: ([URL]) -> Void
    init(_ f: @escaping ([URL]) -> Void) { picked = f }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls) }
}

/// 可以拖动的小圆钮（松手后贴到左 / 右边），点开是菜单
final class FloatingMenuButton: UIView {
    var onTap: () -> Void = {}
    private let icon = UIImageView(image: UIImage(systemName: "circle.grid.2x2.fill"))
    private let gradient = CAGradientLayer()
    private var right = UserDefaults.standard.object(forKey: "menu.right") as? Bool ?? true
    private var yFraction = UserDefaults.standard.object(forKey: "menu.y") as? CGFloat ?? 0.42
    private var area: CGRect = .zero
    private var dragging = false
    private var grab = CGPoint.zero
    static let size: CGFloat = 46

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        gradient.colors = [UIColor(Theme.c1).cgColor, UIColor(Theme.c2).cgColor, UIColor(Theme.c3).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.cornerRadius = Self.size / 2
        gradient.opacity = 0.92
        layer.addSublayer(gradient)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        alpha = 0.85
        accessibilityLabel = L.t("menu_more")
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        icon.frame = bounds.insetBy(dx: 13, dy: 13)
    }

    func layoutIn(_ a: CGRect) {
        area = a
        guard !dragging else { return }
        let x = right ? a.maxX - Self.size - 6 : a.minX + 6
        let y = a.minY + (a.height - Self.size) * min(max(yFraction, 0), 1)
        frame = CGRect(x: x, y: y, width: Self.size, height: Self.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        grab = touches.first?.location(in: self) ?? .zero
        dragging = false
        UIView.animate(withDuration: 0.12) { self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92); self.alpha = 1 }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let sv = superview else { return }
        let p = t.location(in: sv)
        if !dragging, hypot(p.x - center.x, p.y - center.y) < 10 { return }
        dragging = true
        frame.origin = CGPoint(x: p.x - grab.x, y: p.y - grab.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        UIView.animate(withDuration: 0.12) { self.transform = .identity; self.alpha = 0.85 }
        if dragging {
            right = center.x > area.midX
            yFraction = (frame.minY - area.minY) / max(area.height - Self.size, 1)
            UserDefaults.standard.set(right, forKey: "menu.right")
            UserDefaults.standard.set(yFraction, forKey: "menu.y")
            dragging = false
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.5) { self.layoutIn(self.area) }
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        dragging = false
        transform = .identity
        layoutIn(area)
    }
}

/// 把远程画面（UIKit）全屏推出来、收回去（AppModel.showingSession 改了就调用）
enum SessionPresenter {
    static func sync(_ app: AppModel) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let current = findSession(root)
        if app.showingSession, let s = app.session {
            if current?.session === s { return }
            if let current { current.dismiss(animated: false) }
            let vc = SessionController(app: app, session: s)
            var host = root
            while let p = host.presentedViewController, !(p is SessionController) { host = p }
            host.present(vc, animated: true)
        } else if let current, !current.isBeingDismissed {
            current.presentingViewController?.dismiss(animated: true) {
                AppDelegate.orientationLock = .all
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.requestGeometryUpdate(.iOS(interfaceOrientations: .all)) { _ in }
            }
        }
    }

    private static func findSession(_ root: UIViewController) -> SessionController? {
        var v: UIViewController? = root
        while let c = v {
            if let s = c as? SessionController { return s }
            v = c.presentedViewController
        }
        return nil
    }
}

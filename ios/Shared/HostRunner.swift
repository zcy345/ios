import AudioToolbox
import CoreMedia
import ReplayKit
import UIKit
import UserNotifications
import VideoToolbox

/// 这台 iPhone / iPad 做被控端（只能被看）：屏幕广播扩展（SampleHandler）把系统交来的屏幕画面和正在播放的声音交给这里，
/// 这里用 VideoToolbox 编码、Opus 编码，交给 Rust 核心（和 Android 被控端同一份网络代码，`airhand_mobile::host`）。
/// 状态写进 App Group 的共享目录，App 的“共享本机”页显示；App 发来的命令（断开所有人、换控制码……）从那里读。
///
/// 扩展的内存上限很小（约 50 MB）：只保留编码需要的几个缓冲区，Rust 的运行时是固定的两个线程。
final class HostRunner {
    /// 要结束共享（出错了、用户在 App 里点了停止）：广播扩展据此结束广播，原因显示给用户
    var onFail: (String) -> Void = { _ in }
    private var host: Int64 = 0
    private var video: ScreenEncoder?
    private var audio: AppAudioEncoder?
    private var live = HostLive()
    private let stateQueue = DispatchQueue(label: "airhand.broadcast.state")
    private var heartbeat: DispatchSourceTimer?
    private var lastCommand: String?
    private var announced: Set<String> = []
    private var stopping = false

    func start() {
        Native.initialize()
        let s = AppSettings.load()
        guard !s.server.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail(L.t("share_ext_no_server"))
            return
        }
        let screen = ScreenEncoder.screenPixels()
        var cfg: JSON = [
            "server": s.server, "fingerprint": s.fingerprint, "trust": s.trustJson,
            "name": deviceName(s), "os": osName, "identity": IdentityStore.load() ?? NSNull(),
            "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0",
            "displays": [DisplayInfo(index: 0, name: UIDevice.current.model, width: screen.width, height: screen.height, primary: true).json],
            "codecs": ScreenEncoder.codecs.map(\.wire), "input": false, "touch": false, "actions": [String](), "platform": "ios",
            "pairing": PairingFile.load() ?? NSNull(),
        ]
        if let c = SavedHostCode.load() { cfg["reclaim"] = ["code": c.code, "secret": c.secret] } else { cfg["reclaim"] = NSNull() }
        do {
            host = try Native.hostStart(Json.string(cfg))
        } catch {
            fail(L.t("share_ext_failed", "\(error)"))
            return
        }
        live = HostLive(running: true, updated: Date().timeIntervalSince1970)
        live.code = SavedHostCode.load()?.code
        video = ScreenEncoder(host: host)
        audio = AppAudioEncoder(host: host)
        let h = host
        let t = Thread { [weak self] in self?.pump(h) }
        t.name = "airhand-host-events"
        t.start()
        lastCommand = (SharedStore.read(SharedStore.hostCommandFile, as: HostCommand.self))?.id
        IPC.observe(IPC.hostCommand) { [weak self] in self?.command() }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.publish() }
        timer.resume()
        heartbeat = timer
        publish()
    }

    var paused: Bool {
        get { video?.paused ?? false }
        set { video?.paused = newValue }
    }

    func pushVideo(_ sb: CMSampleBuffer) { video?.push(sb) }
    func pushAudio(_ sb: CMSampleBuffer) { audio?.push(sb) }
    /// 开发用：直接交画面 / 声音（模拟器里没有屏幕广播）
    func pushVideo(_ image: CVPixelBuffer, pts: CMTime) { video?.push(image, pts: pts, orientation: .up) }
    func pushAudio(_ pcm: [Int16], rate: Double, ptsUs: Int64) { audio?.push(pcm, rate: rate, ptsUs: ptsUs) }

    func stop() {
        guard !stopping else { return }
        stopping = true
        heartbeat?.cancel()
        video?.stop()
        audio?.active = false
        let h = host
        host = 0
        if h != 0 { Native.hostStop(h) }
        stateQueue.sync {
            live.running = false
            live.viewers = []
            live.updated = Date().timeIntervalSince1970
            live.save()
        }
        IPC.post(IPC.hostLive)
    }

    private func fail(_ message: String) {
        stop()
        onFail(message)
    }

    private var osName: String {
        let d = UIDevice.current
        return "\(d.userInterfaceIdiom == .pad ? "iPadOS" : "iOS") \(d.systemVersion)"
    }

    private func deviceName(_ s: AppSettings) -> String {
        let n = s.deviceName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? UIDevice.current.name : n
    }

    // ── 状态 ──

    private func publish() {
        stateQueue.async {
            guard self.live.running else { return }
            self.live.updated = Date().timeIntervalSince1970
            self.live.save()
            IPC.post(IPC.hostLive)
        }
    }

    private func update(_ f: @escaping (inout HostLive) -> Void) {
        stateQueue.async {
            f(&self.live)
            self.live.updated = Date().timeIntervalSince1970
            self.live.save()
            IPC.post(IPC.hostLive)
        }
    }

    private func pump(_ h: Int64) {
        while host == h {
            guard let text = Native.hostPollEvent(h, 500), let e = Json.parse(text) else { continue }
            switch e.str("type") {
            case "server":
                let st = ServerState.parse(e.obj("state"))
                update {
                    switch st {
                    case .connected: $0.server = "connected"; $0.serverProblem = nil
                    case .connecting: $0.server = "connecting"
                    case .disconnected(let p): $0.server = "disconnected"; $0.serverProblem = Messages.problem(p)
                    }
                }
            case "registered":
                if let code = e.int("code"), let secret = e.str("secret") {
                    SavedHostCode(code: code, secret: secret).save()
                    update { $0.code = code }
                }
            case "pairing":
                if let st = e.obj("state") {
                    PairingFile.save(st)
                    update {
                        $0.pairingCode = st.str("code")
                        $0.pairingLocked = st.bool("locked")
                        $0.pairedCount = st.arr("paired")?.count ?? 0
                    }
                }
            case "controllers":
                let list = (e.arr("list") ?? []).compactMap { $0 as? JSON }.map {
                    HostLive.Viewer(id: $0.str("id") ?? "", key: $0.str("key") ?? "", name: $0.str("name") ?? "", ip: $0.str("ip") ?? "",
                                    safety: $0.str("safety") ?? "", justPaired: $0.bool("justPaired"))
                }
                for v in list where !announced.contains(v.key) {
                    announced.insert(v.key)
                    notify(v)
                }
                update { $0.viewers = list }
            case "video":
                let on = e.bool("active")
                video?.active = on
                update { $0.watching = on }
            case "audio":
                let on = e.bool("active")
                audio?.active = on
                update { $0.audioActive = on }
            case "clipboard":
                if let text = e.str("text"), !text.isEmpty { DispatchQueue.main.async { UIPasteboard.general.string = text } }
            case "clipboardFiles":
                if let key = (e["key"] as? NSNumber)?.int64Value { Native.filesReady(key) }
            case "identity":
                if let k = e.str("key") { IdentityStore.save(k) }
            case "serverTrust":
                if let server = e.str("server"), let fp = e.str("fp") {
                    var s = AppSettings.load()
                    s.trustServer = server
                    s.trustFp = fp
                    s.save()
                }
            default: break
            }
        }
    }

    /// 有设备连上来：通知（同一台设备断线重连不再响）
    private func notify(_ v: HostLive.Viewer) {
        let c = UNMutableNotificationContent()
        let name = v.name.isEmpty ? L.t("unknown_device") : v.name
        c.title = v.justPaired ? L.t("share_ext_paired_title", name) : L.t("share_ext_title", name)
        c.body = L.t("share_ext_text", v.ip, v.safety)
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "viewer-\(v.key)", content: c, trigger: nil))
    }

    /// App 发来的命令
    private func command() {
        guard let c = SharedStore.read(SharedStore.hostCommandFile, as: HostCommand.self), c.id != lastCommand, host != 0 else { return }
        lastCommand = c.id
        switch c.op {
        case "stop":
            fail(L.t("share_stopped_by_user"))
        case "kickAll", "newCode", "newPairingCode", "forgetPaired":
            if c.op == "newCode" { announced.removeAll() }
            if let err = Native.hostCall(host, Json.string(["op": c.op])) { Log.warn("host \(c.op): \(err)") }
        default: break
        }
    }
}

// ───────────────────────────── 画面 ─────────────────────────────

/// ReplayKit 的画面 → 转正、缩放 → VideoToolbox 硬件编码（H.264 / HEVC，低延迟、无 B 帧）→ Annex-B → Rust
final class ScreenEncoder {
    private let host: Int64
    private let queue = DispatchQueue(label: "airhand.broadcast.video", qos: .userInteractive)
    private var session: VTCompressionSession?
    private var rotation: VTPixelRotationSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int) = (0, 0)
    private var rotatedPool: CVPixelBufferPool?
    private var rotatedSize: (Int, Int) = (0, 0)
    private var encodeSize: (w: Int, h: Int) = (0, 0)
    private var codec: Codec = .h264
    private var fps = 30
    private var maxShort = 1080
    private var kbps = 4000
    private var forceKey = true
    private var lastFrameAt: Double = 0
    private var lastPts: CMTime = .invalid
    private var last: CVPixelBuffer?
    private var refinements = 0
    private var displaySize: (Int, Int) = (0, 0)
    private var refine: DispatchSourceTimer?
    private var lastCreateFailure: Double = 0
    var active = false {
        didSet { if active && !oldValue { queue.async { self.forceKey = true } } }
    }
    var paused = false

    static let codecs: [Codec] = {
        var c: [Codec] = [.h264]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { c.append(.h265) }
        return c
    }()

    /// 屏幕的像素大小（竖着）
    static func screenPixels() -> (width: Int, height: Int) {
        let b = UIScreen.main.nativeBounds
        return (Int(b.width), Int(b.height))
    }

    init(host: Int64) {
        self.host = host
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.refineStill() }
        t.resume()
        refine = t
    }

    func stop() {
        refine?.cancel()
        queue.sync {
            if let s = session { VTCompressionSessionInvalidate(s) }
            session = nil
            last = nil
        }
    }

    func push(_ sb: CMSampleBuffer) {
        guard active, !paused, let image = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let orientation = (CMGetAttachment(sb, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        queue.async { self.frame(image, pts, orientation) }
    }

    func push(_ image: CVPixelBuffer, pts: CMTime, orientation: CGImagePropertyOrientation) {
        guard active, !paused else { return }
        queue.async { self.frame(image, pts, orientation) }
    }

    private func applyTick() {
        guard let t = Native.hostTick(host), let j = Json.parse(t) else { return }
        let nc = Codec.fromWire(j.str("codec")) ?? .h264
        let nf = max(1, j.int("fps") ?? 30)
        let nm = j.int("maxShort") ?? 1080
        let nk = max(200, j.int("kbps") ?? 4000)
        if nc != codec || nf != fps || nm != maxShort {
            codec = Self.codecs.contains(nc) ? nc : .h264
            fps = nf
            maxShort = nm
            invalidate()
        }
        if nk != kbps {
            kbps = nk
            if let s = session { setBitrate(s) }
        }
        if j.bool("key") {
            Log.debug("keyframe requested")
            forceKey = true
        }
    }

    private func invalidate() {
        Log.debug("encoder invalidated")
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
        forceKey = true
    }

    private func frame(_ image: CVPixelBuffer, _ pts: CMTime, _ orientation: CGImagePropertyOrientation) {
        applyTick()
        let now = CACurrentMediaTime()
        // 按画面自己的节奏限帧率（留一点余量，不会每隔一阵跳掉一帧）
        if now - lastFrameAt < 1 / Double(fps) - 0.004 { return }
        guard Native.hostWaitWindow(host, 0) else { return }
        guard let prepared = prepare(image, orientation) else { return }
        lastFrameAt = now
        last = prepared
        refinements = 0
        encode(prepared, pts: pts)
    }

    /// 画面停下来 200 ms 后把最后一帧再编几次：编码器只补残差，几帧之内文字就清楚了
    private func refineStill() {
        guard active, !paused, let last, refinements < 6, CACurrentMediaTime() - lastFrameAt > 0.2 else { return }
        applyTick()
        guard Native.hostWaitWindow(host, 0) else { return }
        refinements += 1
        encode(last, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// 转正（横屏时）、缩到短边上限
    private func prepare(_ src: CVPixelBuffer, _ o: CGImagePropertyOrientation) -> CVPixelBuffer? {
        var buf = src
        let rotate: CFString? = {
            switch o {
            case .left, .leftMirrored: return kVTRotation_CW90
            case .right, .rightMirrored: return kVTRotation_CCW90
            case .down, .downMirrored: return kVTRotation_180
            default: return nil
            }
        }()
        if let rotate {
            if rotation == nil {
                VTPixelRotationSessionCreate(nil, &rotation)
            }
            guard let rotation else { return nil }
            VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: rotate)
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let (rw, rh) = rotate == kVTRotation_180 ? (sw, sh) : (sh, sw)
            if rotatedPool == nil || rotatedSize != (rw, rh) {
                rotatedPool = Self.makePool(rw, rh)
                rotatedSize = (rw, rh)
            }
            var out: CVPixelBuffer?
            guard let p = rotatedPool, CVPixelBufferPoolCreatePixelBuffer(nil, p, &out) == kCVReturnSuccess, let out,
                  VTPixelRotationSessionRotateImage(rotation, src, out) == noErr else { return nil }
            buf = out
        }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        if displaySize != (w, h) {
            displaySize = (w, h)
            Native.hostCall(host, Json.string(["op": "displays", "displays": [
                DisplayInfo(index: 0, name: UIDevice.current.model, width: w, height: h, primary: true).json,
            ]]))
            invalidate()
        }
        let short = min(w, h)
        let scale = maxShort > 0 && maxShort < short ? Double(maxShort) / Double(short) : 1
        let tw = max(16, Int((Double(w) * scale / 2).rounded()) * 2), th = max(16, Int((Double(h) * scale / 2).rounded()) * 2)
        if (tw, th) != (encodeSize.w, encodeSize.h) {
            encodeSize = (tw, th)
            invalidate()
        }
        if tw == w && th == h && CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { return buf }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            if let transfer { VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal) }
        }
        if pool == nil || poolSize != (tw, th) {
            pool = Self.makePool(tw, th)
            poolSize = (tw, th)
        }
        var out: CVPixelBuffer?
        guard let transfer, let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: buf, to: out) == noErr else { return nil }
        return out
    }

    private static func makePool(_ w: Int, _ h: Int) -> CVPixelBufferPool? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, attrs as CFDictionary, &p)
        return p
    }

    private func makeSession() -> VTCompressionSession? {
        let (w, h) = encodeSize
        guard w > 0, h > 0 else { return nil }
        // 建不起来的话一秒钟之内不再试（不然每一帧都试一次）
        if CACurrentMediaTime() - lastCreateFailure < 1 { return nil }
        func create(_ codec: Codec, lowLatency: Bool) -> (VTCompressionSession?, OSStatus) {
            var spec: [CFString: Any] = [:]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
                                                codecType: codec == .h265 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            return (st == noErr ? s : nil, st)
        }
        // H.264 用低延迟码率控制（硬件编码器才有）；没有的话用普通的
        var (made, st) = create(codec, lowLatency: codec == .h264)
        if made == nil, codec == .h264 { (made, st) = create(.h264, lowLatency: false) }
        if made == nil, codec != .h264 {
            Log.warn("can't create the \(codec.label) encoder (\(st)), falling back to H.264")
            codec = .h264
            (made, st) = create(.h264, lowLatency: true)
            if made == nil { (made, st) = create(.h264, lowLatency: false) }
        }
        guard let s = made else {
            Log.warn("can't create the \(codec.label) encoder: \(st)")
            lastCreateFailure = CACurrentMediaTime()
            return nil
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: codec == .h265 ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        // 关键帧只在需要时编（新的观看者、丢了帧）：0 = 不限
        let k1 = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 0))
        let k2 = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 0))
        if k1 != noErr || k2 != noErr { Log.debug("key frame interval: \(k1) \(k2)") }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        setBitrate(s)
        VTCompressionSessionPrepareToEncodeFrames(s)
        Native.hostCall(host, Json.string(["op": "encoder", "info": [
            "codec": codec.wire, "name": "VideoToolbox", "hardware": true, "width": w, "height": h,
        ]]))
        return s
    }

    private func setBitrate(_ s: VTCompressionSession) {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: kbps * 1000))
        // 一秒内最多 1.5 倍：大面积变化的那一帧可以大一点，但不让延迟堆起来
        let limits = [NSNumber(value: kbps * 1000 / 8 * 3 / 2), NSNumber(value: 1)] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    private func encode(_ buf: CVPixelBuffer, pts: CMTime) {
        if session == nil { session = makeSession() }
        guard let s = session else { return }
        var props: [CFString: Any] = [:]
        if forceKey {
            props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
            forceKey = false
        }
        let codec = self.codec
        let host = self.host
        let (w, h) = encodeSize
        let captureUs = Int64(pts.seconds * 1_000_000)
        VTCompressionSessionEncodeFrame(s, imageBuffer: buf, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props as CFDictionary, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            ScreenEncoder.deliver(sample, codec: codec, host: host, captureUs: captureUs, w: w, h: h)
        }
    }

    /// 编码器的输出（长度前缀）→ Annex-B；关键帧前面拼上参数集
    private static func deliver(_ sample: CMSampleBuffer, codec: Codec, host: Int64, captureUs: Int64, w: Int, h: Int) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var total = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &ptr) == noErr,
              let ptr else { return }
        // 关键帧看 NAL 的类型（H.264 的 IDR、HEVC 的 IRAP），不只看附件：有的编码器不给每一帧标 NotSync
        let key: Bool = ptr.withMemoryRebound(to: UInt8.self, capacity: total) { b in
            var i = 0
            while i + 5 <= total {
                let len = Int(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
                let h = b[i + 4]
                if codec == .h265 ? (16...21).contains((h >> 1) & 0x3f) : (h & 0x1f) == 5 { return true }
                guard len > 0 else { break }
                i += 4 + len
            }
            return false
        }
        var out = Data(capacity: total + 256)
        let start: [UInt8] = [0, 0, 0, 1]
        if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            if codec == .h265 {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                if codec == .h265 {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                                                                       parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                                                                       parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                if let p {
                    out.append(contentsOf: start)
                    out.append(p, count: n)
                }
            }
        }
        ptr.withMemoryRebound(to: UInt8.self, capacity: total) { b in
            var i = 0
            while i + 4 <= total {
                let len = Int(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
                i += 4
                guard len > 0, i + len <= total else { break }
                out.append(contentsOf: start)
                out.append(b + i, count: len)
                i += len
            }
        }
        out.withUnsafeBytes { Native.hostVideo(host, $0, key: key, config: false, captureUs: captureUs, codec: Int32(codec.rawValue), width: w, height: h) }
    }
}

// ───────────────────────────── 声音 ─────────────────────────────

private final class PcmInput {
    var data: UnsafeRawPointer?
    var bytes: UInt32 = 0
    var frames: UInt32 = 0
    var channels: UInt32 = 2
    var consumed = false
}

private let pcmInputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, _, user in
    let st = Unmanaged<PcmInput>.fromOpaque(user!).takeUnretainedValue()
    if st.consumed || st.data == nil {
        ioPackets.pointee = 0
        return 0x6e6f6d6f
    }
    st.consumed = true
    ioPackets.pointee = st.frames
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: st.data)
    ioData.pointee.mBuffers.mDataByteSize = st.bytes
    ioData.pointee.mBuffers.mNumberChannels = st.channels
    return noErr
}

/// ReplayKit 的 App 声音（采样率、字节序随设备）→ 48 kHz 立体声 Int16 → 每 20 ms 一包 Opus（96 kbps）→ Rust。
/// 没有声音时不发包
final class AppAudioEncoder {
    private let host: Int64
    private let queue = DispatchQueue(label: "airhand.broadcast.audio", qos: .userInitiated)
    private var converter: AudioConverterRef?
    private var sourceFormat: AudioStreamBasicDescription?
    private var encoder: OpusEncoder?
    private var pending: [Int16] = []
    private var pendingStartUs: Int64 = 0
    private var quiet = 0
    private let input = PcmInput()
    private var scratch = [Int16](repeating: 0, count: 48000)
    private var converted = 0
    private var lastLogged = 0
    var active = false {
        didSet { if !active { queue.async { self.pending.removeAll() } } }
    }

    init(host: Int64) {
        self.host = host
        encoder = try? OpusEncoder(channels: 2, bitrate: 96000)
    }

    func push(_ sb: CMSampleBuffer) {
        guard active, let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: &list,
                                                                      bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                                                                      blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              let data = list.mBuffers.mData else { return }
        let bytes = Data(bytes: data, count: Int(list.mBuffers.mDataByteSize))
        let frames = UInt32(CMSampleBufferGetNumSamples(sb))
        queue.async { self.convert(bytes, frames: frames, asbd: asbd, ptsUs: Int64(pts.seconds * 1_000_000)) }
    }

    /// 交错的 Int16 PCM（本机字节序）
    func push(_ pcm: [Int16], rate: Double, ptsUs: Int64) {
        guard active else { return }
        let asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 16, mReserved: 0)
        let bytes = pcm.withUnsafeBytes { Data($0) }
        queue.async { self.convert(bytes, frames: UInt32(pcm.count / 2), asbd: asbd, ptsUs: ptsUs) }
    }

    private func convert(_ bytes: Data, frames: UInt32, asbd: AudioStreamBasicDescription, ptsUs: Int64) {
        if sourceFormat.map({ !same($0, asbd) }) ?? true {
            if let c = converter { AudioConverterDispose(c) }
            var src = asbd
            var dst = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                  mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                                  mBitsPerChannel: 16, mReserved: 0)
            converter = nil
            AudioConverterNew(&src, &dst, &converter)
            sourceFormat = asbd
            input.channels = asbd.mChannelsPerFrame
        }
        guard let converter, let encoder else { return }
        let outFrames = Int(Double(frames) * 48000 / asbd.mSampleRate) + 64
        if scratch.count < outFrames * 2 { scratch = [Int16](repeating: 0, count: outFrames * 2) }
        var produced = UInt32(outFrames)
        bytes.withUnsafeBytes { raw in
            input.data = raw.baseAddress
            input.bytes = UInt32(raw.count)
            input.frames = frames
            input.consumed = false
            scratch.withUnsafeMutableBytes { o in
                var out = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(o.count), mData: o.baseAddress))
                AudioConverterFillComplexBuffer(converter, pcmInputProc, Unmanaged.passUnretained(input).toOpaque(), &produced, &out, nil)
            }
            input.data = nil
        }
        if pending.isEmpty { pendingStartUs = ptsUs }
        #if DEBUG
        converted += Int(produced)
        if converted - lastLogged > 48000 * 2 {
            lastLogged = converted
            Log.info("audio: \(converted) frames converted from \(asbd.mSampleRate) Hz")
        }
        #endif
        pending.append(contentsOf: scratch[0..<Int(produced) * 2])
        while pending.count >= 960 * 2 {
            let chunk = Array(pending[0..<1920])
            pending.removeFirst(1920)
            let startUs = pendingStartUs
            pendingStartUs += 20_000
            // 没有声音（全是很小的值）：不发
            let loud = chunk.contains { abs(Int($0)) > 8 }
            quiet = loud ? 0 : quiet + 1
            if quiet > 10 { continue }
            guard let packet = chunk.withUnsafeBufferPointer({ encoder.encode($0) }) else {
                Log.debug("opus encoder returned no packet")
                continue
            }
            packet.withUnsafeBytes { Native.hostAudio(host, $0, captureUs: startUs) }
        }
    }

    private func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatFlags == b.mFormatFlags && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel && a.mBytesPerFrame == b.mBytesPerFrame
    }
}

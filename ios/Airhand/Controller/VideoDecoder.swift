import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// 一帧画面（媒体包，负载从 `offset` 开始）。确认至多执行一次
final class VideoPacket {
    let seq: UInt32
    let key: Bool
    let codec: Codec
    let width: Int
    let height: Int
    let ptsUs: Int64
    let data: Data
    let offset: Int
    private var ackFn: (() -> Void)?
    var deadlineNs: Int64 = 0

    init(seq: UInt32, key: Bool, codec: Codec, width: Int, height: Int, ptsUs: Int64, data: Data, offset: Int, ack: @escaping () -> Void) {
        self.seq = seq
        self.key = key
        self.codec = codec
        self.width = width
        self.height = height
        self.ptsUs = ptsUs
        self.data = data
        self.offset = offset
        ackFn = ack
    }

    func ack() {
        let f = ackFn
        ackFn = nil
        f?()
    }

    var length: Int { data.count - offset }
}

/// 硬件解码（VideoToolbox），解完马上显示（AVSampleBufferDisplayLayer，标记为立即显示，不排队等时钟）。
///
/// * 低延迟模式送进解码器后确认；音画同步模式在有界等待队列里确认（主动等待不能被当成网络拥塞）；
/// * 格式 / 分辨率 / 参数集变了、解码出错、回到前台：重建解码器，从下一个关键帧开始（主动要关键帧）；
/// * 没有画面视图（不在屏幕上）时收到的帧直接确认、丢掉。
/// 和 Android 的 VideoDecoder.kt 是同一套规则。
final class VideoDecoder {
    private let queue = DispatchQueue(label: "airhand.decode", qos: .userInteractive)
    private let sync: AvSync
    private let requestKeyframe: () -> Void
    private let onTooLarge: (Codec, Int, Int) -> Void

    private var layer: AVSampleBufferDisplayLayer?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var config: (codec: Codec, w: Int, h: Int, params: [Data])?
    private var imageFormat: CMVideoFormatDescription?
    private var pending: [VideoPacket] = []
    private var pendingBytes = 0
    private var needKey = true
    private var lastKeyRequest: Int64 = 0
    private var released = false
    private var decodeAvgNs: Int64 = 0
    private var feedScheduled = false
    private var failures = 0
    /// 解出来的帧数（界面据此知道画面来了）
    private(set) var framesShown = 0
    var onFirstFrame: (() -> Void)?

    init(sync: AvSync, requestKeyframe: @escaping () -> Void, onTooLarge: @escaping (Codec, Int, Int) -> Void) {
        self.sync = sync
        self.requestKeyframe = requestKeyframe
        self.onTooLarge = onTooLarge
    }

    /// 本机能硬件解码的格式（H.264 总是可以）
    static let decodable: [Codec] = {
        var out: [Codec] = [.h264]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { out.append(.h265) }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { out.append(.av1) }
        return out
    }()

    /// 画面视图换了（出现、消失）。换了就从关键帧重新开始
    func setLayer(_ l: AVSampleBufferDisplayLayer?) {
        queue.async {
            if self.layer === l { return }
            self.layer = l
            self.dropPending()
            self.releaseSession()
            self.needKey = true
            if l != nil { self.askKeyframe(force: true) }
        }
    }

    func submit(_ p: VideoPacket) { queue.async { self.onPacket(p) } }

    /// 开关音画同步、声音结束：重新计算等待时间
    func refreshTiming() { queue.async { self.feed() } }

    /// 会话断了重连：之前排队的帧属于旧会话，丢掉（不再确认），从关键帧重新开始
    func resetStream() {
        queue.async {
            self.pending.removeAll()
            self.pendingBytes = 0
            self.releaseSession()
            self.needKey = true
        }
    }

    /// 回到前台：系统可能已经让解码器失效了，从关键帧重新开始
    func restart() {
        queue.async {
            self.dropPending()
            self.releaseSession()
            self.needKey = true
            self.layer?.sampleBufferRenderer.flush()
            self.askKeyframe(force: true)
        }
    }

    func release() {
        queue.async {
            self.released = true
            self.dropPending()
            self.releaseSession()
        }
    }

    private func dropPending() {
        pending.forEach { $0.ack() }
        pending.removeAll()
        pendingBytes = 0
    }

    private func askKeyframe(force: Bool = false) {
        let now = Clock.nowNs
        if force || now - lastKeyRequest > 500_000_000 {
            lastKeyRequest = now
            requestKeyframe()
        }
    }

    private func onPacket(_ p: VideoPacket) {
        guard !released, layer != nil else {
            p.ack()
            return
        }
        let params = p.key ? VideoDecoder.parameterSets(p) : []
        let changed: Bool = {
            guard let c = config, session != nil else { return true }
            if c.codec != p.codec { return true }
            return p.key && (c.w != p.width || c.h != p.height || (!params.isEmpty && params != c.params))
        }()
        if changed {
            guard p.key else {
                p.ack()
                needKey = true
                askKeyframe()
                return
            }
            dropPending()
            guard configure(p, params) else {
                p.ack()
                return
            }
        }
        if needKey {
            guard p.key else {
                p.ack()
                askKeyframe()
                return
            }
            needKey = false
        }
        let arrival = Clock.nowNs
        _ = sync.onVideo(hostUs: p.ptsUs, arrivalNs: arrival, decodeNs: decodeAvgNs)
        p.deadlineNs = arrival + 500_000_000
        pending.append(p)
        pendingBytes += p.length
        if pending.count > (sync.enabled ? 120 : 12) || pendingBytes > 32 << 20 {
            Log.warn("decoder is not keeping up (\(pending.count) frames queued), waiting for a keyframe")
            dropPending()
            releaseSession()
            needKey = true
            askKeyframe(force: true)
            return
        }
        if sync.enabled { p.ack() }
        feed()
    }

    private func feed() {
        while let first = pending.first {
            guard session != nil else { return }
            let now = Clock.nowNs
            let due = min(first.deadlineNs, sync.decodeTimeNs(hostUs: first.ptsUs, nowNs: now, decodeNs: decodeAvgNs))
            let wait = due - now
            if wait > 1_000_000 {
                if !feedScheduled {
                    feedScheduled = true
                    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(wait, 20_000_000)))) {
                        self.feedScheduled = false
                        self.feed()
                    }
                }
                return
            }
            pending.removeFirst()
            pendingBytes -= first.length
            decode(first)
            first.ack()
        }
    }

    // ───────────────────────────── 解码 ─────────────────────────────

    private func configure(_ p: VideoPacket, _ params: [Data]) -> Bool {
        releaseSession()
        var fmt: CMVideoFormatDescription?
        var status: OSStatus = -1
        switch p.codec {
        case .h264:
            guard params.count == 2 else { Log.warn("H.264 keyframe without SPS/PPS"); return false }
            status = withPointers(params) { ptrs, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        case .h265:
            guard params.count == 3 else { Log.warn("HEVC keyframe without VPS/SPS/PPS"); return false }
            status = withPointers(params) { ptrs, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
            }
        case .av1:
            guard let seq = params.first, let av1C = AV1.configRecord(sequenceHeaderObu: seq) else {
                Log.warn("AV1 keyframe without a sequence header")
                return false
            }
            let ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": av1C]]
            status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AV1, width: Int32(p.width), height: Int32(p.height),
                                                    extensions: ext as CFDictionary, formatDescriptionOut: &fmt)
        }
        guard status == noErr, let fmt else {
            Log.warn("can't describe the \(p.codec.label) stream: \(status)")
            requestKeyframeSoon()
            return false
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else {
            Log.warn("can't start the \(p.codec.label) decoder for \(p.width)x\(p.height): \(st)")
            if p.width * p.height > 1920 * 1080 { onTooLarge(p.codec, p.width, p.height) }
            requestKeyframeSoon()
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        format = fmt
        config = (p.codec, p.width, p.height, params)
        Log.info("decoder started: \(p.codec.label) \(p.width)x\(p.height)")
        return true
    }

    private func requestKeyframeSoon() {
        needKey = true
        askKeyframe()
    }

    private func releaseSession() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        format = nil
        config = nil
        decodeAvgNs = 0
    }

    private func decode(_ p: VideoPacket) {
        guard let s = session, let fmt = format else { return }
        guard let sample = makeSample(p, fmt) else {
            fail("can't build a sample")
            return
        }
        let start = Clock.nowNs
        var flags = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample, flags: [], infoFlagsOut: &flags) { [weak self] status, info, image, _, _ in
            guard let self else { return }
            if status != noErr {
                self.queue.async { self.fail("decode error \(status)") }
                return
            }
            guard let image, !info.contains(.frameDropped) else { return }
            let elapsed = min(max(Clock.nowNs - start, 0), 500_000_000)
            self.decodeAvgNs = self.decodeAvgNs == 0 ? elapsed : self.decodeAvgNs + (elapsed - self.decodeAvgNs) / 10
            self.show(image, pts: p.ptsUs)
        }
        if st != noErr {
            fail("decode \(st)")
        } else {
            failures = 0
        }
    }

    private func fail(_ why: String) {
        failures += 1
        Log.warn("video decoder: \(why)")
        dropPending()
        releaseSession()
        needKey = true
        askKeyframe(force: failures < 3)
    }

    /// 解出来的画面交给显示层（立即显示；音画同步时最多再等 50 ms）
    private func show(_ image: CVImageBuffer, pts: Int64) {
        guard let layer else { return }
        if imageFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(imageFormat!, imageBuffer: image) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &f)
            imageFormat = f
        }
        guard let imageFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: imageFormat,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary], let a = arr.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let enqueue = {
            let r = layer.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sb)
            self.framesShown += 1
            if self.framesShown == 1 { self.onFirstFrame?() }
        }
        if sync.enabled {
            let now = Clock.nowNs
            let due = sync.renderTimeNs(hostUs: pts, nowNs: now)
            if due - now > 2_000_000 {
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(due - now))) { if self.layer === layer { enqueue() } }
                return
            }
        }
        enqueue()
    }

    // ───────────────────────────── 码流 ─────────────────────────────

    private func makeSample(_ p: VideoPacket, _ fmt: CMVideoFormatDescription) -> CMSampleBuffer? {
        let payload: Data = p.data.withUnsafeBytes { raw in
            let b = UnsafeRawBufferPointer(rebasing: raw[p.offset...])
            switch p.codec {
            case .h264, .h265: return AnnexB.toLengthPrefixed(b, codec: p.codec)
            case .av1: return AV1.stripTemporalDelimiters(b)
            }
        }
        guard !payload.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let ok = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        guard ok == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: p.ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    /// 关键帧里的参数集：H.264 是 SPS、PPS，HEVC 是 VPS、SPS、PPS，AV1 是序列头 OBU
    static func parameterSets(_ p: VideoPacket) -> [Data] {
        p.data.withUnsafeBytes { raw -> [Data] in
            let b = UnsafeRawBufferPointer(rebasing: raw[p.offset...])
            switch p.codec {
            case .h264:
                let nals = AnnexB.split(b)
                guard let sps = nals.first(where: { b[$0.lowerBound] & 0x1f == 7 }),
                      let pps = nals.first(where: { b[$0.lowerBound] & 0x1f == 8 }) else { return [] }
                return [Data(b[sps]), Data(b[pps])]
            case .h265:
                let nals = AnnexB.split(b)
                func find(_ t: UInt8) -> Data? { nals.first { (b[$0.lowerBound] >> 1) & 0x3f == t }.map { Data(b[$0]) } }
                guard let vps = find(32), let sps = find(33), let pps = find(34) else { return [] }
                return [vps, sps, pps]
            case .av1:
                return AV1.sequenceHeader(b).map { [$0] } ?? []
            }
        }
    }
}

private func withPointers(_ sets: [Data], _ f: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> OSStatus) -> OSStatus {
    let copies = sets.map { d -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
        d.copyBytes(to: p, count: d.count)
        return p
    }
    defer { copies.forEach { $0.deallocate() } }
    let ptrs = copies.map { UnsafePointer($0) }
    let sizes = sets.map(\.count)
    return ptrs.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { ss in f(pp.baseAddress!, ss.baseAddress!) } }
}

/// Annex-B 码流（起始码分隔的 NAL 单元）
enum AnnexB {
    /// 各个 NAL 单元（不含起始码）的范围
    static func split(_ b: UnsafeRawBufferPointer) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let n = b.count
        var start = -1
        var i = 0
        while i + 2 < n {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var e = i
                    while e > start, b[e - 1] == 0 { e -= 1 }
                    if e > start { out.append(start..<e) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { out.append(start..<n) }
        return out
    }

    /// 换成 4 字节长度前缀（VideoToolbox 要的格式），参数集和分隔符不放进去（在格式描述里）
    static func toLengthPrefixed(_ b: UnsafeRawBufferPointer, codec: Codec) -> Data {
        var out = Data(capacity: b.count + 16)
        for r in split(b) {
            let t = codec == .h264 ? b[r.lowerBound] & 0x1f : (b[r.lowerBound] >> 1) & 0x3f
            if codec == .h264, t == 7 || t == 8 || t == 9 { continue }
            if codec == .h265, (32...35).contains(t) { continue }
            var len = UInt32(r.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(contentsOf: b[r])
        }
        return out
    }
}

/// AV1：OBU 码流（低开销格式，带长度字段）
enum AV1 {
    /// 各个 OBU：(类型, 整个 OBU 的范围)
    static func obus(_ b: UnsafeRawBufferPointer) -> [(type: UInt8, range: Range<Int>)] {
        var out: [(UInt8, Range<Int>)] = []
        var i = 0
        while i < b.count {
            let h = b[i]
            let type = (h >> 3) & 0x0f
            let ext = h & 0x04 != 0
            let hasSize = h & 0x02 != 0
            var j = i + 1 + (ext ? 1 : 0)
            var size = b.count - j
            if hasSize {
                var v = 0
                var shift = 0
                while j < b.count {
                    let byte = b[j]
                    v |= Int(byte & 0x7f) << shift
                    j += 1
                    if byte & 0x80 == 0 { break }
                    shift += 7
                    if shift > 56 { return out }
                }
                size = v
            }
            let end = j + size
            guard end <= b.count, j <= end else { break }
            out.append((type, i..<end))
            i = end
        }
        return out
    }

    static func sequenceHeader(_ b: UnsafeRawBufferPointer) -> Data? {
        obus(b).first { $0.type == 1 }.map { Data(b[$0.range]) }
    }

    static func stripTemporalDelimiters(_ b: UnsafeRawBufferPointer) -> Data {
        var out = Data(capacity: b.count)
        for o in obus(b) where o.type != 2 { out.append(contentsOf: b[o.range]) }
        return out
    }

    /// av1C（AV1CodecConfigurationRecord）：从序列头 OBU 里读出档次、级别、位深和色度采样
    static func configRecord(sequenceHeaderObu obu: Data) -> Data? {
        obu.withUnsafeBytes { b -> Data? in
            guard b.count > 2 else { return nil }
            let ext = b[0] & 0x04 != 0
            let hasSize = b[0] & 0x02 != 0
            var start = 1 + (ext ? 1 : 0)
            if hasSize { while start < b.count, b[start] & 0x80 != 0 { start += 1 }; start += 1 }
            guard start < b.count else { return nil }
            var r = BitReader(UnsafeRawBufferPointer(rebasing: b[start...]))
            let profile = r.bits(3)
            _ = r.bits(1) // still_picture
            let reduced = r.bits(1) == 1
            var level = 0, tier = 0
            if reduced {
                level = r.bits(5)
            } else {
                var decoderModel = false
                var bufferDelayLen = 0
                if r.bits(1) == 1 { // timing_info_present
                    _ = r.bits(32); _ = r.bits(32)
                    if r.bits(1) == 1 { r.uvlc() }
                    decoderModel = r.bits(1) == 1
                    if decoderModel {
                        bufferDelayLen = r.bits(5) + 1
                        _ = r.bits(32); _ = r.bits(5); _ = r.bits(5)
                    }
                }
                let initialDisplayDelay = r.bits(1) == 1
                let count = r.bits(5) + 1
                for i in 0..<count {
                    _ = r.bits(12)
                    let l = r.bits(5)
                    let t = l > 7 ? r.bits(1) : 0
                    if i == 0 { level = l; tier = t }
                    if decoderModel, r.bits(1) == 1 { _ = r.bits(bufferDelayLen); _ = r.bits(bufferDelayLen); _ = r.bits(1) }
                    if initialDisplayDelay, r.bits(1) == 1 { _ = r.bits(4) }
                }
            }
            let wBits = r.bits(4) + 1
            let hBits = r.bits(4) + 1
            _ = r.bits(wBits); _ = r.bits(hBits)
            if !reduced, r.bits(1) == 1 { _ = r.bits(4); _ = r.bits(3) }
            _ = r.bits(3) // use_128x128, filter_intra, intra_edge
            if !reduced {
                _ = r.bits(4) // interintra, masked, warped, dual_filter
                let orderHint = r.bits(1) == 1
                if orderHint { _ = r.bits(2) }
                var forceScreen = 2
                if r.bits(1) == 0 { forceScreen = r.bits(1) }
                if forceScreen > 0, r.bits(1) == 0 { _ = r.bits(1) }
                if orderHint { _ = r.bits(3) }
            }
            _ = r.bits(3) // superres, cdef, restoration
            // color_config
            let high = r.bits(1)
            var twelve = 0
            if profile == 2, high == 1 { twelve = r.bits(1) }
            let mono = profile == 1 ? 0 : r.bits(1)
            var cp = 2, tc = 2, mc = 2
            if r.bits(1) == 1 { cp = r.bits(8); tc = r.bits(8); mc = r.bits(8) }
            var sx = 1, sy = 1, csp = 0
            if mono == 1 {
                _ = r.bits(1)
            } else if cp == 1, tc == 13, mc == 0 {
                sx = 0; sy = 0
            } else {
                _ = r.bits(1) // color_range
                if profile == 0 { sx = 1; sy = 1 } else if profile == 1 { sx = 0; sy = 0 } else if twelve == 1 {
                    sx = r.bits(1)
                    sy = sx == 1 ? r.bits(1) : 0
                } else { sx = 1; sy = 0 }
                if sx == 1, sy == 1 { csp = r.bits(2) }
            }
            guard !r.overrun else { return nil }
            var out = Data([0x81, UInt8(profile << 5 | level),
                            UInt8(tier << 7 | high << 6 | twelve << 5 | mono << 4 | sx << 3 | sy << 2 | csp), 0])
            out.append(obu)
            return out
        }
    }

    struct BitReader {
        let b: UnsafeRawBufferPointer
        var pos = 0
        var overrun = false
        init(_ b: UnsafeRawBufferPointer) { self.b = b }

        mutating func bits(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byte = pos >> 3
                guard byte < b.count else { overrun = true; return v }
                v = v << 1 | Int((b[byte] >> (7 - UInt8(pos & 7))) & 1)
                pos += 1
            }
            return v
        }

        mutating func uvlc() {
            var zeros = 0
            while bits(1) == 0 && !overrun { zeros += 1; if zeros >= 32 { return } }
            _ = bits(zeros)
        }
    }
}

import AVFoundation
import Foundation
import os

/// 一个 Opus 包（48 kHz 立体声，20 ms），带着采集时间和到达时刻（抖动缓冲据此量晚到量）
struct AudioPacket {
    var start: Bool
    var ptsUs: Int64
    var data: Data
    var arrivedNs: Int64
}

/// 声音的输入输出：一个 AVAudioEngine 同时负责播放对方的声音和录本机的麦克风
/// （同一个引擎才能做回声消除：对方的声音从扬声器放出来，不会再被录回去）
final class AudioIO {
    static let shared = AudioIO()

    typealias Render = (_ frames: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ outputNs: Int64) -> Void
    typealias Tap = (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private var renderLock = os_unfair_lock()
    private var render: Render?
    private var tap: Tap?
    private var latencyNs: Int64 = 0
    private let queue = DispatchQueue(label: "airhand.audio.io")

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        source = AVAudioSourceNode(format: format) { [unowned self] _, ts, frames, list in
            let abl = UnsafeMutableAudioBufferListPointer(list)
            guard abl.count >= 2, let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frames)
            let host = ts.pointee.mFlags.contains(.hostTimeValid) ? Clock.hostTimeToNs(ts.pointee.mHostTime) : Clock.nowNs
            os_unfair_lock_lock(&self.renderLock)
            let f = self.render
            let lat = self.latencyNs
            os_unfair_lock_unlock(&self.renderLock)
            if let f {
                f(n, l, r, host + lat)
            } else {
                for i in 0..<n { l[i] = 0; r[i] = 0 }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.updateLatency()
        }
    }

    func setPlayer(_ r: Render?) {
        os_unfair_lock_lock(&renderLock)
        render = r
        os_unfair_lock_unlock(&renderLock)
        queue.async { self.restart() }
    }

    func setMic(_ t: Tap?) throws {
        var err: Error?
        queue.sync {
            tap = t
            do { try configure() } catch { err = error }
        }
        if let err { throw err }
    }

    private func restart() { try? configure() }

    private func updateLatency() {
        let s = AVAudioSession.sharedInstance()
        let ns = Int64((s.outputLatency + s.ioBufferDuration) * 1e9)
        os_unfair_lock_lock(&renderLock)
        latencyNs = ns
        os_unfair_lock_unlock(&renderLock)
    }

    private func configure() throws {
        os_unfair_lock_lock(&renderLock)
        let playing = render != nil
        os_unfair_lock_unlock(&renderLock)
        let mic = tap != nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let s = AVAudioSession.sharedInstance()
        guard playing || mic else {
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        if mic {
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        } else {
            try s.setCategory(.playback, mode: .default, options: [])
        }
        try? s.setPreferredSampleRate(48000)
        try? s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
        if mic {
            try? engine.inputNode.setVoiceProcessingEnabled(true)
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 480, format: fmt) { [weak self] buf, _ in
                self?.tap?(buf)
            }
        } else if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine.prepare()
        try engine.start()
        updateLatency()
    }
}

/// Opus 解码 → 自适应 PCM 抖动缓冲 → 声卡（和 Android 的 AudioPlayer.kt 一样）
final class AudioPlayer {
    private let sync: AvSync
    private let token: Int64
    private let onFailure: (String) -> Void
    private let queue = DispatchQueue(label: "airhand.audio.decode", qos: .userInteractive)
    private var decoder: OpusDecoder?
    private var lock = os_unfair_lock()
    private let jitter = JitterBuffer()
    private var lastPcmNs = Clock.nowNs
    private var lastClockNs = Int64.min
    private var running = true
    #if DEBUG
    private var decodedFrames = 0, loggedFrames = 0, peak = 0, playedFrames = 0
    #endif

    init(sync: AvSync, token: Int64, onFailure: @escaping (String) -> Void) {
        self.sync = sync
        self.token = token
        self.onFailure = onFailure
        do {
            decoder = try OpusDecoder(channels: 2)
        } catch {
            onFailure("\(error)")
            running = false
            return
        }
        AudioIO.shared.setPlayer { [weak self] n, l, r, outNs in
            self?.render(n, l, r, outNs) ?? { for i in 0..<n { l[i] = 0; r[i] = 0 } }()
        }
    }

    func submit(_ p: AudioPacket) {
        guard running else { return }
        queue.async { self.decode(p) }
    }

    func release() {
        running = false
        AudioIO.shared.setPlayer(nil)
    }

    private func decode(_ p: AudioPacket) {
        guard running, let decoder else { return }
        let frames = p.data.withUnsafeBytes { decoder.decode($0) }
        guard frames > 0 else { return }
        #if DEBUG
        decodedFrames += frames
        peak = max(peak, decoder.pcm[0..<frames * 2].map { abs(Int($0)) }.max() ?? 0)
        if decodedFrames - loggedFrames >= 48000 * 2 {
            loggedFrames = decodedFrames
            Log.info("audio: decoded \(decodedFrames) frames, peak \(peak), played \(playedFrames)")
            peak = 0
        }
        #endif
        // 第一包会裁掉编码器前瞻：裁掉的是开头的采样
        let skipped = max(960 - frames, 0)
        decoder.pcm.withUnsafeBufferPointer { pcm in
            os_unfair_lock_lock(&lock)
            jitter.push(pcm, frames: frames, start: p.start, hostUs: p.ptsUs + Int64(skipped) * 1_000_000 / 48000,
                        arrivedMs: Double(p.arrivedNs) / 1e6)
            lastPcmNs = Clock.nowNs
            os_unfair_lock_unlock(&lock)
        }
    }

    private func render(_ n: Int, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ outNs: Int64) {
        let now = Clock.nowNs
        os_unfair_lock_lock(&lock)
        jitter.setExtraDelay(sync.extraMs)
        let clock = jitter.pull(left: l, right: r, frames: n, finishBurst: now - lastPcmNs > 100_000_000)
        #if DEBUG
        if clock != nil { playedFrames += n }
        #endif
        os_unfair_lock_unlock(&lock)
        if let clock, lastClockNs == .min || now - lastClockNs >= 100_000_000 {
            sync.onAudioClock(token: token, hostUs: clock.hostUs, localNs: outNs, appliedMs: clock.appliedMs, nowNs: now)
            lastClockNs = now
        }
    }
}

/// 本机麦克风 → 48 kHz 单声道 → Opus（32 kbps，每包 20 ms）→ 声音包，交给被控端的虚拟麦克风
final class MicCapture {
    private let deliver: (Data) -> Void
    private var encoder: OpusEncoder?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
    private var pending: [Int16] = []
    private var seq: UInt32 = 0
    private var first = true
    private let queue = DispatchQueue(label: "airhand.mic", qos: .userInteractive)

    init(deliver: @escaping (Data) -> Void) { self.deliver = deliver }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() throws {
        encoder = try OpusEncoder(channels: 1, bitrate: 32000)
        try AudioIO.shared.setMic { [weak self] buf in self?.onBuffer(buf) }
    }

    func stop() {
        try? AudioIO.shared.setMic(nil)
        queue.async { self.encoder = nil }
    }

    private func onBuffer(_ buf: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: target)
        }
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 48000 / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        let captureUs = UInt64(Clock.nowNs / 1000)
        queue.async { self.append(samples, captureUs) }
    }

    private func append(_ s: [Int16], _ captureUs: UInt64) {
        guard let encoder else { return }
        pending.append(contentsOf: s)
        while pending.count >= 960 {
            let frame = Array(pending.prefix(960))
            pending.removeFirst(960)
            guard let opus = frame.withUnsafeBufferPointer({ encoder.encode($0) }) else { continue }
            seq &+= 1
            let packet = Media.audioPacket(seq: seq, start: first, captureUs: captureUs, opus: opus)
            first = false
            deliver(packet)
        }
    }
}

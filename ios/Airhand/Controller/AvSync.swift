import Foundation

/// 音频 / 视频共用的采集时钟映射；本地时间统一用 Clock.nowNs（主机时钟）。和 Android 的 AvSync.kt 一样
final class AvSync {
    private struct VideoSample { var atNs: Int64; var offsetNs: Int64 }

    private let lock = NSLock()
    private(set) var enabled = false
    private(set) var extraMs = 0
    private var audioNs: Int64?
    private var audioBaseNs: Int64?
    private var audioAtNs = Int64.min
    private var video: [VideoSample] = []
    private var lastUpdateNs = Int64.min
    private var generation: Int64 = 0

    private static let ms: Int64 = 1_000_000
    private static let displayNs: Int64 = 8 * ms
    private static let maxVideoDelayNs: Int64 = 500 * ms

    /// 每次启停声音换一代，已经退出的播放器不能污染新会话的时钟
    func reset() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        audioNs = nil
        audioBaseNs = nil
        audioAtNs = .min
        video.removeAll()
        extraMs = 0
        lastUpdateNs = .min
        return generation
    }

    func setEnabled(_ v: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled == v { return }
        enabled = v
        extraMs = 0
        video.removeAll()
        lastUpdateNs = .min
    }

    func onAudioClock(token: Int64, hostUs: Int64, localNs: Int64, appliedMs: Double, nowNs: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return }
        let off = localNs - hostUs * 1000
        if let old = audioNs, abs(off - old) <= 40 * Self.ms {
            audioNs = old + (off - old) / 10
        } else {
            audioNs = off
        }
        audioBaseNs = audioNs! - Int64(appliedMs * Double(Self.ms))
        audioAtNs = nowNs
    }

    func onVideo(hostUs: Int64, arrivalNs: Int64, decodeNs: Int64) -> Int64 {
        lock.lock()
        video.append(VideoSample(atNs: arrivalNs, offsetNs: arrivalNs + decodeNs + Self.displayNs - hostUs * 1000))
        while let f = video.first, f.atNs < arrivalNs - 3000 * Self.ms || video.count > 600 { video.removeFirst() }
        update(arrivalNs)
        lock.unlock()
        return decodeTimeNs(hostUs: hostUs, nowNs: arrivalNs, decodeNs: decodeNs)
    }

    func decodeTimeNs(hostUs: Int64, nowNs: Int64, decodeNs: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let audio = currentAudio(nowNs) else { return nowNs }
        return min(max(hostUs * 1000 + audio - decodeNs - Self.displayNs, nowNs), nowNs + Self.maxVideoDelayNs)
    }

    /// 解码前承担大部分等待；显示只承担剩余的少量延迟
    func renderTimeNs(hostUs: Int64, nowNs: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let audio = currentAudio(nowNs) else { return nowNs }
        return min(max(hostUs * 1000 + audio, nowNs), nowNs + 50 * Self.ms)
    }

    private func currentAudio(_ nowNs: Int64) -> Int64? {
        guard enabled, let a = audioNs, (0...(500 * Self.ms)).contains(nowNs - audioAtNs) else { return nil }
        return a
    }

    private func update(_ nowNs: Int64) {
        guard currentAudio(nowNs) != nil, let base = audioBaseNs else {
            extraMs = 0
            return
        }
        if video.count < 10 || (lastUpdateNs != .min && nowNs - lastUpdateNs < 2000 * Self.ms) { return }
        let offsets = video.map(\.offsetNs).sorted()
        let want = min(max(Double(offsets[Int(Double(offsets.count) * 0.9)] - base) / Double(Self.ms), 0), 300)
        var next = extraMs
        if want > Double(extraMs + 15) {
            next = min(Int((want + 5).rounded()), 300)
        } else if want < Double(extraMs - 30) {
            next = want > 0 ? min(Int((want + 5).rounded()), 300) : 0
        }
        if next != extraMs {
            extraMs = next
            lastUpdateNs = nowNs
        }
    }
}

/// PCM 抖动缓冲（交错立体声 Int16）。先攒数据再播放，轻微变速吸收网络抖动和两端声卡时钟漂移
/// （与控制台的 jitter.ts、Android 的 AudioBuffer.kt 同一套做法）。不加锁：调用方负责
final class JitterBuffer {
    struct ClockInfo { var hostUs: Int64; var appliedMs: Double }
    private struct Anchor { var pos: Int64; var hostUs: Int64 }

    private let rate: Int
    private let perMs: Double
    private let capacity: Int
    private var samples: [Int16]
    private var anchors: [Anchor] = []
    private var written: Int64 = 0
    private var read: Double = 0
    private var playing = false
    private var starved = false
    private var rebuffer = false
    private var target: Double
    private var extra: Double = 0
    private var average: Double = 0
    private var low = Double.infinity
    private var calm: Double = 0
    private var windowLeft: Int
    private var fade = 0
    private let fadeFrames: Int
    private var lateBase = Double.nan
    private var lateAt: Double = 0
    private var lateNow: Double = 0
    private var lateWindows = [Double](repeating: 0, count: 30)
    private var lateIndex = 0

    private static let minTargetMs = 40.0
    private static let maxTargetMs = 400.0
    private static let lateMarginMs = 30.0
    private static let maxLateMs = 250.0
    private static let baseLeakMsPerS = 10.0

    init(rate: Int = 48_000) {
        self.rate = rate
        perMs = Double(rate) / 1000
        capacity = rate * 2
        samples = [Int16](repeating: 0, count: rate * 4)
        target = 60 * Double(rate) / 1000
        windowLeft = rate * 2
        fadeFrames = max(1, Int((Double(rate) * 0.003).rounded()))
    }

    private var goal: Double { target + extra }

    func setExtraDelay(_ ms: Int) {
        let next = Double(min(max(ms, 0), 300)) * perMs
        if playing && next - extra > 60 * perMs { rebuffer = true }
        extra = next
    }

    /// 写入一个解码后的包。`start` = 静音后的第一包；`hostUs` = 第一个采样的采集时间；`arrivedMs` = 到达时刻
    func push(_ pcm: UnsafeBufferPointer<Int16>, frames count: Int, start: Bool, hostUs: Int64, arrivedMs: Double?) {
        guard count > 0 else { return }
        if starved {
            starved = false
            if !start {
                target = min(Self.maxTargetMs * perMs, target + 20 * perMs)
                calm = 0
            }
        }
        if let a = arrivedMs { measure(a, Double(hostUs) / 1000) }
        let offset = max(0, count - (capacity - 2))
        let frames = count - offset
        if written + Int64(frames) - Int64(read) > Int64(capacity - 2) {
            read = Double(written + Int64(frames) - Int64(capacity - 2))
            fade = 0
        }
        anchors.append(Anchor(pos: written, hostUs: hostUs + Int64(offset) * 1_000_000 / Int64(rate)))
        for i in 0..<frames {
            let dst = Int((written + Int64(i)) % Int64(capacity)) * 2
            samples[dst] = pcm[(offset + i) * 2]
            samples[dst + 1] = pcm[(offset + i) * 2 + 1]
        }
        written += Int64(frames)
        pruneAnchors()
    }

    /// 填充 `frames` 帧到两个声道（Float），返回这一块第一个采样的采集时钟。静音 / 重新缓冲时不报告时钟
    func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, finishBurst: Bool) -> ClockInfo? {
        for i in 0..<frames { left[i] = 0; right[i] = 0 }
        if !playing {
            if Double(written) <= read || (Double(written) - read < goal && !finishBurst) { return nil }
            playing = true
            fade = 0
            average = Double(written) - read
        }
        if Double(written) - read > goal + 150 * perMs {
            read = Double(written) - goal
            average = goal
            fade = 0
        }
        pruneAnchors()
        var clock: ClockInfo?
        if let a = anchors.first, Double(a.pos) <= read, !rebuffer {
            clock = ClockInfo(hostUs: a.hostUs + Int64((read - Double(a.pos)) * 1_000_000 / Double(rate)),
                              appliedMs: min(extra, max(average - target, 0)) / perMs)
        }
        low = min(low, Double(written) - read)
        average += (Double(written) - read - average) * 0.02
        let errorMs = (average - goal) / perMs
        let adjustment: Double = errorMs > 10 ? min(0.02, (errorMs - 10) / 2000) : (errorMs < -10 ? -min(0.01, (-errorMs - 10) / 2000) : 0)
        let step = finishBurst ? 1.0 : 1 + adjustment
        var i = 0
        while i < frames {
            let pos = Int64(read.rounded(.down))
            if pos >= written || (pos + 1 >= written && !finishBurst) { break }
            let fraction = read - Double(pos)
            let a = Int(pos % Int64(capacity)) * 2
            let b = Int(min(pos + 1, written - 1) % Int64(capacity)) * 2
            var gain: Double = 1
            if fade < fadeFrames { gain = Double(fade) / Double(fadeFrames); fade += 1 }
            if rebuffer { gain *= 1 - Double(i) / Double(frames) }
            let l = Double(samples[a]) + Double(Int(samples[b]) - Int(samples[a])) * fraction
            let r = Double(samples[a + 1]) + Double(Int(samples[b + 1]) - Int(samples[a + 1])) * fraction
            left[i] = Float(l * gain / 32768)
            right[i] = Float(r * gain / 32768)
            read = min(Double(written), read + step)
            i += 1
        }
        if i < frames {
            playing = false
            starved = !rebuffer
        }
        if rebuffer {
            rebuffer = false
            playing = false
        }
        calm += Double(i) * step
        windowLeft -= frames
        if windowLeft <= 0 {
            windowLeft = rate * 2
            let floor = min(max(recentLate() + Self.lateMarginMs, Self.minTargetMs), Self.maxTargetMs) * perMs
            lateWindows[lateIndex] = lateNow
            lateIndex = (lateIndex + 1) % lateWindows.count
            lateNow = 0
            if playing && calm >= Double(rate * 20) && low > 25 * perMs + extra && target > floor { target = max(target - 5 * perMs, floor) }
            low = .infinity
        }
        return i > 0 ? clock : nil
    }

    private func recentLate() -> Double { lateWindows.reduce(lateNow, max) }

    private func measure(_ nowMs: Double, _ hostMs: Double) {
        let delay = nowMs - hostMs
        if !lateBase.isNaN { lateBase += max(nowMs - lateAt, 0) * Self.baseLeakMsPerS / 1000 }
        lateAt = nowMs
        if lateBase.isNaN || delay < lateBase {
            lateBase = delay
            return
        }
        let late = delay - lateBase
        if late > Self.maxLateMs {
            lateBase = delay
            return
        }
        lateNow = max(lateNow, late)
        target = max(target, min(Self.maxTargetMs, late + Self.lateMarginMs) * perMs)
    }

    private func pruneAnchors() {
        while anchors.count > 1 && (Double(anchors[1].pos) <= read || anchors.count > 256) { anchors.removeFirst() }
    }
}

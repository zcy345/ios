#if DEBUG
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// 开发用（-AirhandHostSelfTest 1）：模拟器里没有屏幕广播，用合成的画面（走动的彩条）和声音（440 Hz）
/// 跑一遍被控端（和广播扩展同一份 HostRunner），再用 android/native 的 probe 连上来看收到的画面和声音
enum DebugHost {
    private static var runner: HostRunner?
    private static var timer: Timer?

    static func start() {
        let r = HostRunner()
        r.onFail = { Log.error("host self-test failed: \($0)") }
        r.start()
        runner = r
        var n = 0
        // 先画好 12 帧（彩条错开），之后轮流交出去：调试构建里每帧画 300 万个像素太慢
        var frames: [CVPixelBuffer] = []
        for k in 0..<12 {
            var buf: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1170, 2532, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &buf)
            guard let buf else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), stride = CVPixelBufferGetBytesPerRow(buf)
            let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            var row0 = [UInt8](repeating: 255, count: stride)
            for x in 0..<w {
                let band = ((x + k * 15) / 90) % 6
                row0[x * 4] = UInt8([40, 200, 90, 250, 30, 160][band])
                row0[x * 4 + 1] = UInt8([200, 60, 220, 120, 90, 30][band])
                row0[x * 4 + 2] = UInt8([230, 90, 40, 180, 240, 120][band])
            }
            for y in 0..<h { row0.withUnsafeBytes { (p + y * stride).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: stride) } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            frames.append(buf)
        }
        var phase = 0.0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            n += 1
            let buf = frames[n % frames.count]
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            r.pushVideo(buf, pts: now)
            // 33 ms 的 440 Hz（44.1 kHz，检查重采样）
            let frames = 1470
            var pcm = [Int16](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let v = Int16(sin(phase) * 8000)
                pcm[i * 2] = v
                pcm[i * 2 + 1] = v
                phase += 2 * .pi * 440 / 44100
            }
            r.pushAudio(pcm, rate: 44100, ptsUs: Int64(now.seconds * 1_000_000))
        }
    }
}
#endif

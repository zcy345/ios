import AudioToolbox
import Foundation

/// Opus 编解码（系统的 AudioToolbox，48 kHz，每包 20 ms = 960 帧）。和桌面版、Android 的声音包是同一个格式
private final class ConverterInput {
    var data: UnsafeRawPointer?
    var size: UInt32 = 0
    var packets: UInt32 = 0
    var channels: UInt32 = 2
    var consumed = false
    let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    deinit { desc.deallocate() }
}

/// 数据给完了（不是错误）：AudioConverterFillComplexBuffer 会把它原样返回
private let noMoreData: OSStatus = 0x6e6f6d6f // 'nomo'

private let inputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, user in
    let st = Unmanaged<ConverterInput>.fromOpaque(user!).takeUnretainedValue()
    if st.consumed || st.data == nil {
        ioPackets.pointee = 0
        return noMoreData
    }
    st.consumed = true
    ioPackets.pointee = st.packets
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: st.data)
    ioData.pointee.mBuffers.mDataByteSize = st.size
    ioData.pointee.mBuffers.mNumberChannels = st.channels
    if let outDesc {
        st.desc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: st.size)
        outDesc.pointee = st.desc
    }
    return noErr
}

private func pcmFormat(_ channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
                                mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
}

private func opusFormat(_ channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
}

struct OpusError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "Opus (AudioToolbox) error \(status)" }
}

/// Opus 解码 → 交错的 Int16 PCM
final class OpusDecoder {
    private var conv: AudioConverterRef?
    private let input = ConverterInput()
    let channels: UInt32
    /// 一包最多 120 ms
    private(set) var pcm = [Int16](repeating: 0, count: 5760 * 2)

    init(channels: UInt32 = 2) throws {
        self.channels = channels
        var src = opusFormat(channels)
        var dst = pcmFormat(channels)
        let st = AudioConverterNew(&src, &dst, &conv)
        guard st == noErr, conv != nil else { throw OpusError(status: st) }
        input.channels = channels
    }

    deinit { if let conv { AudioConverterDispose(conv) } }

    /// 解一包，返回帧数（结果在 `pcm` 里）
    func decode(_ packet: UnsafeRawBufferPointer) -> Int {
        guard let conv, packet.count > 0 else { return 0 }
        input.data = packet.baseAddress
        input.size = UInt32(packet.count)
        input.packets = 1
        input.consumed = false
        var frames = UInt32(5760)
        let st: OSStatus = pcm.withUnsafeMutableBytes { out in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(out.count), mData: out.baseAddress))
            return AudioConverterFillComplexBuffer(conv, inputProc, Unmanaged.passUnretained(input).toOpaque(), &frames, &list, nil)
        }
        input.data = nil
        if st != noErr && st != noMoreData { return 0 }
        return Int(frames)
    }
}

/// 交错的 Int16 PCM（每次正好 960 帧）→ Opus 包
final class OpusEncoder {
    private var conv: AudioConverterRef?
    private let input = ConverterInput()
    let channels: UInt32
    private var out = [UInt8](repeating: 0, count: 4000)
    private let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    init(channels: UInt32, bitrate: UInt32) throws {
        self.channels = channels
        var src = pcmFormat(channels)
        var dst = opusFormat(channels)
        let st = AudioConverterNew(&src, &dst, &conv)
        guard st == noErr, let conv else { throw OpusError(status: st) }
        var br = bitrate
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
        input.channels = channels
    }

    deinit {
        if let conv { AudioConverterDispose(conv) }
        desc.deallocate()
    }

    /// 编一包（`pcm` 是 960 帧），编码器还没攒够时返回 nil
    func encode(_ pcm: UnsafeBufferPointer<Int16>) -> Data? {
        guard let conv, pcm.count >= 960 * Int(channels) else { return nil }
        input.data = UnsafeRawPointer(pcm.baseAddress)
        input.size = UInt32(960 * 2 * Int(channels))
        input.packets = 960
        input.consumed = false
        var packets = UInt32(1)
        let st: OSStatus = out.withUnsafeMutableBytes { o in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(o.count), mData: o.baseAddress))
            let r = AudioConverterFillComplexBuffer(conv, inputProc, Unmanaged.passUnretained(input).toOpaque(), &packets, &list, desc)
            o.withMemoryRebound(to: UInt8.self) { _ in }
            if r == noErr || r == noMoreData { lastSize = Int(list.mBuffers.mDataByteSize) }
            return r
        }
        input.data = nil
        guard (st == noErr || st == noMoreData), packets > 0, lastSize > 0 else { return nil }
        return Data(out[0..<lastSize])
    }

    private var lastSize = 0
}

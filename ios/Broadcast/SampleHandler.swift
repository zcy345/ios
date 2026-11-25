import ReplayKit

/// 屏幕广播扩展的入口：系统交来的画面、声音交给 HostRunner（Shared/HostRunner.swift），它做被控端的所有事
final class SampleHandler: RPBroadcastSampleHandler {
    private let runner = HostRunner()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        runner.onFail = { [weak self] message in
            self?.finishBroadcastWithError(NSError(domain: "app.airhand", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        runner.start()
    }

    override func broadcastPaused() { runner.paused = true }
    override func broadcastResumed() { runner.paused = false }
    override func broadcastFinished() { runner.stop() }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video: runner.pushVideo(sampleBuffer)
        case .audioApp: runner.pushAudio(sampleBuffer)
        default: break
        }
    }
}

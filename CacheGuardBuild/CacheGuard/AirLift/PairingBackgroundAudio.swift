import AVFAudio
import Foundation

/// Keeps the local RPPairing host alive while the user switches to Settings.
/// Enabled only while the user explicitly runs pairing. Requires audio background mode.
@MainActor
final class PairingBackgroundAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var active = false

    func start() {
        guard !active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            engine.attach(player)
            let format = engine.outputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { stop(); return }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let frameCount = AVAudioFrameCount(max(1024, Int(format.sampleRate)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                stop(); return
            }
            buffer.frameLength = frameCount
            if let channels = buffer.floatChannelData {
                for index in 0..<Int(format.channelCount) {
                    memset(channels[index], 0, Int(frameCount) * MemoryLayout<Float>.size)
                }
            }
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            active = true
        } catch {
            stop()
        }
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
        if player.engine != nil { engine.detach(player) }
        active = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

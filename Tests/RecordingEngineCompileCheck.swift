import Foundation

@main
enum RecordingEngineCompileCheck {
    static func main() {
        let engine = RecordingEngine()
        engine.onWarning = { _ in }
        engine.onAudioLevels = { _, _ in }
        print("Recording engine compile check passed")
    }
}

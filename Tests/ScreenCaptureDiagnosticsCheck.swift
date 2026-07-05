import Foundation
import ScreenCaptureKit

@main
enum ScreenCaptureDiagnosticsCheck {
    static func main() {
        let denied = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.userDeclined.rawValue
        )
        check(ScreenCaptureDiagnostics.isPermissionDenial(denied), "permission denial")
        check(
            ScreenCaptureDiagnostics.appError(from: denied).errorDescription?.contains("não foi autorizada") == true,
            "permission message"
        )

        let audioFailure = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.failedToStartAudioCapture.rawValue
        )
        check(!ScreenCaptureDiagnostics.isPermissionDenial(audioFailure), "audio failure is not denial")
        check(
            ScreenCaptureDiagnostics.appError(from: audioFailure).errorDescription?.contains("outro app") == true,
            "audio failure guidance"
        )

        let unrelated = NSError(domain: "PontoGrava.Test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Falha de teste"
        ])
        check(!ScreenCaptureDiagnostics.isPermissionDenial(unrelated), "unrelated error")
        check(
            ScreenCaptureDiagnostics.appError(from: unrelated).errorDescription?.contains("Falha de teste") == true,
            "unrelated error preserved"
        )
        print("Screen capture diagnostics checks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            fputs("Screen capture diagnostics check failed: \(name)\n", stderr)
            exit(1)
        }
    }
}

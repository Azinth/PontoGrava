import Foundation
import ScreenCaptureKit

enum ScreenCaptureDiagnostics {
    static func appError(from error: Error) -> AppError {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            return .screenCaptureFailed(nsError.localizedDescription)
        }

        switch nsError.code {
        case SCStreamError.userDeclined.rawValue:
            return .screenPermissionDenied
        case SCStreamError.failedToStartAudioCapture.rawValue:
            return .screenCaptureFailed(
                "O macOS não conseguiu iniciar o áudio do sistema. " +
                "Se outro app estiver compartilhando ou gravando a tela, encerre essa captura e tente novamente."
            )
        case SCStreamError.failedToStartMicrophoneCapture.rawValue:
            return .screenCaptureFailed(
                "O macOS não conseguiu iniciar o microfone selecionado. " +
                "Confirme que o fone ou microfone continua conectado e tente novamente."
            )
        case SCStreamError.systemStoppedStream.rawValue:
            return .screenCaptureFailed(
                "O macOS interrompeu o serviço de captura. Tente iniciar a gravação novamente."
            )
        default:
            return .screenCaptureFailed(nsError.localizedDescription)
        }
    }

    static func isPermissionDenial(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.userDeclined.rawValue
    }
}

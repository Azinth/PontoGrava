import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Abrir PontoGrava") {
            openWindow(id: "main")
        }

        Divider()

        if model.isRecordingSession {
            Button("Mostrar controles") {
                model.showRecordingPanel()
            }

            if model.isPaused {
                Button("Continuar gravação") {
                    model.resumeRecording()
                }
            } else {
                Button("Pausar gravação") {
                    model.pauseRecording()
                }
            }

            Button("Parar e transcrever") {
                Task { await model.stopRecording() }
            }
        } else {
            Button("Iniciar gravação") {
                Task { await model.beginRecording() }
            }
            .disabled(model.isBusy || model.selectedMicrophoneID == nil)

            Button("Importar áudio…") {
                model.presentImportPanel()
            }
            .disabled(model.isBusy)
        }

        Divider()

        Text("Microfone: \(model.selectedMicrophoneName)")
        Button("Abrir pasta de gravações") { model.openOutputFolder() }

        Divider()

        Button("Sair") { NSApplication.shared.terminate(nil) }
    }
}

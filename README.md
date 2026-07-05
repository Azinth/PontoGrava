# PontoGrava

Aplicativo nativo para macOS que grava áudio do sistema e o microfone selecionado,
gera um WAV combinado e transcreve localmente com WhisperKit.

Durante a gravação, um painel flutuante mostra o tempo ativo, o microfone fixado e
os níveis reais das duas fontes. Os controles também ficam disponíveis na barra de
menus. Pausas mantêm a captura aberta, descartam os buffers recebidos e são
removidas do WAV, da duração e dos timestamps da transcrição.

O histórico permite reproduzir o WAV no próprio app, renomear título e pasta em
conjunto e mover uma reunião completa para a Lixeira. Notificações locais avisam
quando a transcrição termina ou quando o áudio foi preservado após uma falha.

A captura usa o próprio ScreenCaptureKit como fonte de verdade para autorização.
O preflight do CoreGraphics é informativo e não bloqueia o início da gravação.

## Requisitos

- macOS 15 ou mais recente
- Apple Silicon
- Swift 6 / Xcode 16 ou Command Line Tools compatíveis
- Internet apenas no primeiro download do modelo Whisper

## Executar em desenvolvimento

```bash
swift run PontoGrava
```

## Gerar o aplicativo

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
open "outputs/PontoGrava.app"
```

## Testes disponíveis neste Mac

```bash
chmod +x scripts/test.sh
scripts/test.sh
```

O Command Line Tools instalado não inclui XCTest; o script compila e executa as
verificações puras diretamente com `swiftc`.

O build local usa assinatura ad hoc. Como a identidade muda quando o binário é
recompilado, cada nova versão local pode exigir que a autorização de gravação seja
desativada e ativada novamente nos Ajustes do Sistema.

## Benchmark neste Mac

No Apple M5 com 16 GB, o modelo `large-v3-v20240930_626MB` transcreveu uma amostra
em português de 56,5 segundos em 6,72 segundos após o primeiro carregamento. A
primeira execução é mais lenta porque baixa o modelo e prepara o Core ML.

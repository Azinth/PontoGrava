#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/work/tests"
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/Models.swift" \
  "$ROOT/Sources/MeetingScribe/TranscriptFormatting.swift" \
  "$ROOT/Tests/SmokeChecks.swift" \
  -o "$ROOT/work/tests/SmokeChecks"

"$ROOT/work/tests/SmokeChecks"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/DiscordIntegration.swift" \
  "$ROOT/Tests/DiscordIntegrationCheck.swift" \
  -framework Security \
  -o "$ROOT/work/tests/DiscordIntegrationCheck"

"$ROOT/work/tests/DiscordIntegrationCheck"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/Models.swift" \
  "$ROOT/Sources/MeetingScribe/TranscriptFormatting.swift" \
  "$ROOT/Sources/MeetingScribe/SpeakerAttribution.swift" \
  "$ROOT/Tests/SpeakerAttributionCheck.swift" \
  -framework AVFoundation \
  -o "$ROOT/work/tests/SpeakerAttributionCheck"

"$ROOT/work/tests/SpeakerAttributionCheck"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/Models.swift" \
  "$ROOT/Sources/MeetingScribe/AudioProcessing.swift" \
  "$ROOT/Sources/MeetingScribe/AudioImportService.swift" \
  "$ROOT/Tests/AudioMixerCheck.swift" \
  -framework AVFoundation \
  -framework CoreMedia \
  -o "$ROOT/work/tests/AudioMixerCheck"

"$ROOT/work/tests/AudioMixerCheck"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/Models.swift" \
  "$ROOT/Sources/MeetingScribe/MeetingStore.swift" \
  "$ROOT/Sources/MeetingScribe/MeetingFileService.swift" \
  "$ROOT/Tests/MeetingManagementCheck.swift" \
  -framework AppKit \
  -o "$ROOT/work/tests/MeetingManagementCheck"

"$ROOT/work/tests/MeetingManagementCheck"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/Models.swift" \
  "$ROOT/Sources/MeetingScribe/AudioPlaybackController.swift" \
  "$ROOT/Tests/AudioPlaybackCheck.swift" \
  -framework AVFoundation \
  -o "$ROOT/work/tests/AudioPlaybackCheck"

"$ROOT/work/tests/AudioPlaybackCheck"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/Models.swift" \
  "$ROOT/Sources/MeetingScribe/AudioProcessing.swift" \
  "$ROOT/Sources/MeetingScribe/ScreenCaptureDiagnostics.swift" \
  "$ROOT/Sources/MeetingScribe/RecordingEngine.swift" \
  "$ROOT/Tests/RecordingEngineCompileCheck.swift" \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework ScreenCaptureKit \
  -o "$ROOT/work/tests/RecordingEngineCompileCheck"

"$ROOT/work/tests/RecordingEngineCompileCheck"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  "$ROOT/Sources/MeetingScribe/Models.swift" \
  "$ROOT/Sources/MeetingScribe/ScreenCaptureDiagnostics.swift" \
  "$ROOT/Tests/ScreenCaptureDiagnosticsCheck.swift" \
  -framework ScreenCaptureKit \
  -o "$ROOT/work/tests/ScreenCaptureDiagnosticsCheck"

"$ROOT/work/tests/ScreenCaptureDiagnosticsCheck"

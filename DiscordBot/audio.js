import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, join, relative } from 'node:path';
import { Transform } from 'node:stream';

const runningCommands = new Set();

export function normalizedPCMLevel(buffer) {
  const sampleCount = Math.floor(buffer.length / 2);
  if (sampleCount === 0) return 0;
  let sum = 0;
  for (let offset = 0; offset < sampleCount * 2; offset += 2) {
    const sample = buffer.readInt16LE(offset) / 32768;
    sum += sample * sample;
  }
  const rms = Math.sqrt(sum / sampleCount);
  if (rms <= 0.000_001) return 0;
  return Math.max(0, Math.min(1, (20 * Math.log10(rms) + 60) / 60));
}

export function createPCMLevelMeter(onLevel) {
  return new Transform({
    transform(chunk, _encoding, callback) {
      onLevel(normalizedPCMLevel(chunk));
      callback(null, chunk);
    }
  });
}

export function markClipFirstPacket(clip, sessionStartedAt, now = Date.now) {
  if (Number.isFinite(clip.offsetMs)) return false;
  const startedAt = Date.parse(sessionStartedAt);
  const receivedAt = Number(now());
  clip.offsetMs = Number.isFinite(startedAt) && Number.isFinite(receivedAt)
    ? Math.max(0, receivedAt - startedAt)
    : 0;
  return true;
}

export class AudioLevelReporter {
  constructor(send, intervalMs = 100, now = Date.now) {
    this.send = send;
    this.intervalMs = intervalMs;
    this.now = now;
    this.levels = new Map();
    this.smoothedLevel = 0;
    this.lastSentAt = -Infinity;
  }

  update(id, level) {
    this.levels.set(id, level);
    const maximum = Math.max(0, ...this.levels.values());
    const factor = maximum > this.smoothedLevel ? 0.58 : 0.16;
    this.smoothedLevel += (maximum - this.smoothedLevel) * factor;
    const now = this.now();
    if (now - this.lastSentAt >= this.intervalMs) {
      this.send(this.smoothedLevel);
      this.lastSentAt = now;
    }
  }

  remove(id) {
    if (!this.levels.delete(id)) return;
    if (this.levels.size === 0) this.reset();
  }

  reset() {
    this.levels.clear();
    this.smoothedLevel = 0;
    this.send(0);
    this.lastSentAt = this.now();
  }
}

export class SpeakerCaptureCoordinator {
  constructor({
    beginCapture,
    isSpeaking,
    onError = () => {},
    onRestart = () => {},
    errorRetryMs = 50
  }) {
    this.beginCapture = beginCapture;
    this.isSpeaking = isSpeaking;
    this.onError = onError;
    this.onRestart = onRestart;
    this.errorRetryMs = errorRetryMs;
    this.captures = new Map();
    this.pending = new Set();
    this.scheduled = new Map();
    this.stopped = false;
  }

  request(userId) {
    if (this.stopped) return null;
    const active = this.captures.get(userId);
    if (active) {
      if (active.ending) active.restartRequested = true;
      return active.task;
    }

    if (this.scheduled.has(userId)) {
      const timer = this.scheduled.get(userId);
      if (timer) clearTimeout(timer);
      this.scheduled.delete(userId);
    }

    const capture = {
      ending: false,
      restartRequested: false,
      error: null,
      task: null
    };
    this.captures.set(userId, capture);
    const markEnding = () => {
      if (this.captures.get(userId) === capture) capture.ending = true;
    };

    let finished;
    try {
      finished = this.beginCapture(userId, { markEnding });
    } catch (error) {
      finished = Promise.reject(error);
    }
    capture.task = Promise.resolve(finished)
      .catch(error => {
        capture.error = error;
        if (!this.stopped) {
          try {
            this.onError(userId, error);
          } catch {}
        }
      })
      .then(() => this.complete(userId, capture));
    this.pending.add(capture.task);
    capture.task.finally(() => this.pending.delete(capture.task));
    return capture.task;
  }

  complete(userId, capture) {
    if (this.captures.get(userId) !== capture) return;
    this.captures.delete(userId);
    if (this.stopped) return;

    let shouldRestart = capture.restartRequested;
    if (!shouldRestart) {
      try {
        shouldRestart = this.isSpeaking(userId);
      } catch {}
    }
    if (!shouldRestart) return;
    try {
      this.onRestart(userId);
    } catch {}
    const delay = capture.error ? this.errorRetryMs : 0;
    const restart = () => {
      this.scheduled.delete(userId);
      this.request(userId);
    };
    if (delay > 0) {
      this.scheduled.set(userId, setTimeout(restart, delay));
    } else {
      this.scheduled.set(userId, null);
      queueMicrotask(restart);
    }
  }

  stop() {
    this.stopped = true;
    for (const timer of this.scheduled.values()) {
      if (timer) clearTimeout(timer);
    }
    this.scheduled.clear();
  }

  async settle() {
    while (this.pending.size > 0) {
      await Promise.allSettled([...this.pending]);
    }
  }
}

export function locateFFmpeg() {
  const candidates = ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'];
  return candidates.find(existsSync) ?? 'ffmpeg';
}

export function safeName(value) {
  return value.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 80) || 'participant';
}

export function writeJSONAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, path);
}

export function readSession(folderPath) {
  return JSON.parse(readFileSync(join(folderPath, '.discord', 'session.json'), 'utf8'));
}

export function recordingCommandError(recording, guildId, channelId) {
  if (!recording) return 'Não há uma gravação do Discord em andamento.';
  if (guildId !== recording.session.guildId || channelId !== recording.session.channelId) {
    return 'Use este comando no chat do canal de voz que está sendo gravado.';
  }
  if (recording.stopping) return 'A gravação já está sendo finalizada.';
  return null;
}

export function startRecordingCommandError(recording, pending, channelId, memberVoiceChannelId) {
  if (recording) return 'Já existe uma gravação do Discord em andamento.';
  if (pending) return 'Outra gravação do Discord já está sendo iniciada.';
  if (!channelId || channelId !== memberVoiceChannelId) {
    return 'Use /start no chat do canal de voz em que você está.';
  }
  return null;
}

function run(executable, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    runningCommands.add(child);
    let error = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', chunk => { error = `${error}${chunk}`.slice(-65_536); });
    child.on('error', reject);
    child.on('close', code => {
      runningCommands.delete(child);
      if (code === 0) resolve();
      else reject(new Error(error.trim() || `FFmpeg terminou com código ${code}`));
    });
  });
}

export function terminateRunningCommands() {
  for (const child of runningCommands) child.kill('SIGKILL');
}

export function participantFilter(clips) {
  const delayed = clips.map((clip, index) =>
    `[${index}:a]adelay=${Math.max(0, Math.round(clip.offsetMs))}:all=1[a${index}]`
  );
  const inputs = clips.map((_, index) => `[a${index}]`).join('');
  return `${delayed.join(';')};${inputs}amix=inputs=${clips.length}:duration=longest:normalize=0,` +
    'apad,loudnorm=I=-18:TP=-2:LRA=11,aresample=16000[out]';
}

function diagnosticCount(value) {
  return Math.max(0, Math.trunc(Number(value) || 0));
}

export function buildCaptureDiagnostics(session, emptyClips = new Map()) {
  const diagnostics = new Map();
  const ensure = (userId, displayName = null) => {
    if (!diagnostics.has(userId)) {
      diagnostics.set(userId, {
        userId,
        displayName: displayName ?? userId,
        automaticRestarts: 0,
        streamErrors: 0,
        emptyClips: 0
      });
    }
    const participant = diagnostics.get(userId);
    if (displayName) participant.displayName = displayName;
    return participant;
  };

  for (const participant of session.captureDiagnostics?.participants ?? []) {
    const normalized = ensure(participant.userId, participant.displayName);
    normalized.automaticRestarts = diagnosticCount(participant.automaticRestarts);
    normalized.streamErrors = diagnosticCount(participant.streamErrors);
    normalized.emptyClips = diagnosticCount(participant.emptyClips);
  }
  for (const clip of session.clips ?? []) ensure(clip.userId, clip.displayName);
  for (const [userId, count] of emptyClips) {
    ensure(userId).emptyClips += diagnosticCount(count);
  }

  return {
    participants: [...diagnostics.values()]
      .sort((a, b) => a.displayName.localeCompare(b.displayName, 'pt-BR'))
  };
}

export async function finalizeSession(folderPath, ffmpegPath = locateFFmpeg()) {
  const hidden = join(folderPath, '.discord');
  const sessionPath = join(hidden, 'session.json');
  const manifestPath = join(hidden, 'manifest.json');
  const session = readSession(folderPath);
  const recoveredDuration = Math.max(
    0,
    ...session.clips.map(clip => Number(clip.endedOffsetMs) || Number(clip.offsetMs) + 1000)
  ) / 1000;
  const durationSeconds = Math.max(0.1, Number(session.durationSeconds) || recoveredDuration);
  const emptyClips = new Map();
  const usableClips = session.clips.filter(clip => {
    const path = join(hidden, clip.path);
    if (!existsSync(path)) return false;
    const stats = statSync(path);
    if (!stats.isFile()) return false;
    if (stats.size > 0) return true;
    emptyClips.set(clip.userId, (emptyClips.get(clip.userId) ?? 0) + 1);
    return false;
  });
  if (usableClips.length === 0) {
    rmSync(sessionPath, { force: true });
    throw new Error('Nenhum áudio foi recebido do canal do Discord.');
  }

  const tracksFolder = join(hidden, 'tracks');
  mkdirSync(tracksFolder, { recursive: true });
  const grouped = Map.groupBy(usableClips, clip => clip.userId);
  const participants = [];

  for (const [userId, clips] of grouped) {
    const trackPath = join(tracksFolder, `${safeName(userId)}.wav`);
    const temporaryTrackPath = `${trackPath}.${process.pid}.tmp.wav`;
    const args = clips.flatMap(clip => clip.format === 's16le'
      ? ['-f', 's16le', '-ar', '48000', '-ac', '2', '-i', join(hidden, clip.path)]
      : ['-i', join(hidden, clip.path)]
    );
    args.push(
      '-y', '-filter_complex', participantFilter(clips),
      '-map', '[out]', '-ac', '1', '-c:a', 'pcm_s16le',
      '-t', durationSeconds.toFixed(3), temporaryTrackPath
    );
    try {
      await run(ffmpegPath, args);
      renameSync(temporaryTrackPath, trackPath);
    } finally {
      rmSync(temporaryTrackPath, { force: true });
    }
    participants.push({
      userId,
      displayName: clips.at(-1).displayName,
      trackPath: relative(folderPath, trackPath)
    });
  }

  const audioPath = join(folderPath, 'audio.wav');
  const temporaryAudioPath = `${audioPath}.${process.pid}.tmp.wav`;
  const mixInputs = participants.flatMap(participant => ['-i', join(folderPath, participant.trackPath)]);
  const mixFilter = participants.length === 1
    ? '[0:a]aresample=48000[out]'
    : `${participants.map((_, index) => `[${index}:a]`).join('')}amix=inputs=${participants.length}:duration=longest:normalize=0,alimiter=limit=0.95,aresample=48000[out]`;
  try {
    await run(ffmpegPath, [
      ...mixInputs, '-y', '-filter_complex', mixFilter, '-map', '[out]',
      '-ar', '48000', '-ac', '2', '-c:a', 'pcm_f32le',
      '-t', durationSeconds.toFixed(3), temporaryAudioPath
    ]);
    renameSync(temporaryAudioPath, audioPath);
  } finally {
    rmSync(temporaryAudioPath, { force: true });
  }

  const manifest = {
    version: 2,
    status: 'complete',
    guildId: session.guildId,
    guildName: session.guildName,
    channelId: session.channelId,
    channelName: session.channelName,
    startedAt: session.startedAt,
    durationSeconds,
    participants: participants.sort((a, b) => a.displayName.localeCompare(b.displayName, 'pt-BR')),
    captureDiagnostics: buildCaptureDiagnostics(session, emptyClips)
  };
  writeJSONAtomic(manifestPath, manifest);
  rmSync(sessionPath, { force: true });
  return { ...manifest, folderPath, audioPath, manifestPath };
}

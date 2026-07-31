import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Readable } from 'node:stream';
import prism from 'prism-media';
import {
  AudioLevelReporter,
  SpeakerCaptureCoordinator,
  buildCaptureDiagnostics,
  createPCMLevelMeter,
  finalizeSession,
  locateFFmpeg,
  markClipFirstPacket,
  normalizedPCMLevel,
  participantFilter,
  recordingCommandError,
  safeName,
  startRecordingCommandError,
  writeJSONAtomic
} from './audio.js';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function flushTasks() {
  return new Promise(resolve => setImmediate(resolve));
}

test('normalizes silent, audible and maximum PCM levels', () => {
  assert.equal(normalizedPCMLevel(Buffer.alloc(16)), 0);
  const audible = Buffer.alloc(16);
  for (let offset = 0; offset < audible.length; offset += 2) audible.writeInt16LE(8_000, offset);
  assert.ok(normalizedPCMLevel(audible) > 0);
  const maximum = Buffer.alloc(16);
  for (let offset = 0; offset < maximum.length; offset += 2) maximum.writeInt16LE(-32_768, offset);
  assert.equal(normalizedPCMLevel(maximum), 1);
});

test('meters PCM without changing the bytes', async () => {
  const input = Buffer.from([0, 0, 255, 127, 0, 128, 42, 0]);
  const levels = [];
  const output = [];
  for await (const chunk of Readable.from([input]).pipe(createPCMLevelMeter(level => levels.push(level)))) {
    output.push(chunk);
  }
  assert.deepEqual(Buffer.concat(output), input);
  assert.equal(levels.length, 1);
});

test('aggregates speakers and limits regular events to ten per second', () => {
  let now = 0;
  const events = [];
  const reporter = new AudioLevelReporter(level => events.push({ level, at: now }), 100, () => now);
  reporter.update('ana', 0.4);
  now = 50;
  reporter.update('beto', 0.8);
  now = 100;
  reporter.update('ana', 0.3);
  assert.equal(events.length, 2);
  assert.ok(events[1].level > events[0].level);
  assert.ok(events[1].at - events[0].at >= 100);
  reporter.remove('ana');
  reporter.remove('beto');
  assert.equal(events.at(-1).level, 0);
});

test('does not duplicate a healthy participant capture', async () => {
  const active = deferred();
  let starts = 0;
  const coordinator = new SpeakerCaptureCoordinator({
    beginCapture: () => {
      starts += 1;
      return active.promise;
    },
    isSpeaking: () => false
  });

  const first = coordinator.request('ana');
  assert.equal(coordinator.request('ana'), first);
  assert.equal(starts, 1);
  active.resolve();
  await first;
  assert.equal(starts, 1);
  coordinator.stop();
  await coordinator.settle();
});

test('restarts after a new speaking event arrives while the old capture is ending', async () => {
  const captures = [];
  const coordinator = new SpeakerCaptureCoordinator({
    beginCapture: (_userId, state) => {
      const capture = { ...deferred(), ...state };
      captures.push(capture);
      return capture.promise;
    },
    isSpeaking: () => false
  });

  const first = coordinator.request('ana');
  captures[0].markEnding();
  coordinator.request('ana');
  assert.equal(captures.length, 1);
  captures[0].resolve();
  await first;
  await flushTasks();
  assert.equal(captures.length, 2);

  coordinator.stop();
  captures[1].resolve();
  await coordinator.settle();
});

test('recovers one participant at the silence boundary without duplicating another', async () => {
  const captures = new Map();
  const coordinator = new SpeakerCaptureCoordinator({
    beginCapture: (userId, state) => {
      const capture = { ...deferred(), ...state };
      const userCaptures = captures.get(userId) ?? [];
      userCaptures.push(capture);
      captures.set(userId, userCaptures);
      return capture.promise;
    },
    isSpeaking: () => false
  });

  coordinator.request('ana');
  coordinator.request('beto');
  captures.get('ana')[0].markEnding();
  coordinator.request('ana');
  coordinator.request('beto');
  captures.get('ana')[0].resolve();
  await flushTasks();

  assert.equal(captures.get('ana').length, 2);
  assert.equal(captures.get('beto').length, 1);

  coordinator.stop();
  captures.get('ana')[1].resolve();
  captures.get('beto')[0].resolve();
  await coordinator.settle();
});

test('restarts a failed capture while the participant is still speaking', async () => {
  const second = deferred();
  let starts = 0;
  let errors = 0;
  let restarts = 0;
  const coordinator = new SpeakerCaptureCoordinator({
    beginCapture: () => {
      starts += 1;
      return starts === 1 ? Promise.reject(new Error('decoder failed')) : second.promise;
    },
    isSpeaking: () => true,
    onError: () => { errors += 1; },
    onRestart: () => { restarts += 1; },
    errorRetryMs: 0
  });

  coordinator.request('ana');
  await flushTasks();
  assert.equal(starts, 2);
  assert.equal(errors, 1);
  assert.equal(restarts, 1);

  coordinator.stop();
  second.resolve();
  await coordinator.settle();
});

test('does not restart captures after recording stops', async () => {
  const capture = deferred();
  let starts = 0;
  let markEnding;
  const coordinator = new SpeakerCaptureCoordinator({
    beginCapture: (_userId, state) => {
      starts += 1;
      markEnding = state.markEnding;
      return capture.promise;
    },
    isSpeaking: () => true
  });

  coordinator.request('ana');
  markEnding();
  coordinator.request('ana');
  coordinator.stop();
  capture.resolve();
  await coordinator.settle();
  await flushTasks();
  assert.equal(starts, 1);
});

test('sanitizes participant ids used as filenames', () => {
  assert.equal(safeName('../user:42'), '.._user_42');
});

test('aligns overlapping clips before mixing', () => {
  const filter = participantFilter([{ offsetMs: 0 }, { offsetMs: 1250 }]);
  assert.match(filter, /\[0:a\]adelay=0:all=1/);
  assert.match(filter, /\[1:a\]adelay=1250:all=1/);
  assert.match(filter, /amix=inputs=2/);
  assert.match(filter, /apad/);
  assert.match(filter, /loudnorm=I=-18:TP=-2:LRA=11/);
  assert.doesNotMatch(filter, /atrim/);
});

test('aligns a recovered capture to its first packet instead of its idle subscription', () => {
  const clip = { offsetMs: null };
  const startedAt = '2026-07-24T18:06:25.000Z';

  assert.equal(markClipFirstPacket(
    clip,
    startedAt,
    () => Date.parse('2026-07-24T18:06:29.000Z')
  ), true);
  assert.equal(clip.offsetMs, 4_000);
  assert.equal(markClipFirstPacket(
    clip,
    startedAt,
    () => Date.parse('2026-07-24T18:06:35.000Z')
  ), false);
  assert.equal(clip.offsetMs, 4_000);
  assert.match(participantFilter([clip], 5), /adelay=4000:all=1/);
});

test('normalizes v2 capture diagnostics and counts discarded empty clips', () => {
  const diagnostics = buildCaptureDiagnostics({
    captureDiagnostics: {
      participants: [{
        userId: '1',
        displayName: 'Ana',
        automaticRestarts: 2,
        streamErrors: 1,
        emptyClips: 1
      }]
    },
    clips: [
      { userId: '1', displayName: 'Ana' },
      { userId: '2', displayName: 'Beto' }
    ]
  }, new Map([['1', 2]]));

  assert.deepEqual(diagnostics.participants, [
    {
      userId: '1',
      displayName: 'Ana',
      automaticRestarts: 2,
      streamErrors: 1,
      emptyClips: 3
    },
    {
      userId: '2',
      displayName: 'Beto',
      automaticRestarts: 0,
      streamErrors: 0,
      emptyClips: 0
    }
  ]);
});

test('accepts stop only in the active channel and while not finalizing', () => {
  const active = { session: { guildId: 'guild', channelId: 'channel' } };
  assert.match(recordingCommandError(null, 'guild', 'channel'), /Não há/);
  assert.match(recordingCommandError(active, 'guild', 'other'), /chat do canal/);
  assert.equal(recordingCommandError(active, 'guild', 'channel'), null);
  active.stopping = true;
  assert.match(recordingCommandError(active, 'guild', 'channel'), /finalizada/);
});

test('accepts start only from the member voice channel while idle', () => {
  assert.match(startRecordingCommandError({}, null, 'channel', 'channel'), /Já existe/);
  assert.match(startRecordingCommandError(null, {}, 'channel', 'channel'), /sendo iniciada/);
  assert.match(startRecordingCommandError(null, null, 'text', 'voice'), /chat do canal/);
  assert.match(startRecordingCommandError(null, null, 'voice', null), /chat do canal/);
  assert.equal(startRecordingCommandError(null, null, 'voice', 'voice'), null);
});

test('loads the Opus decoder used for received voice packets', () => {
  assert.doesNotThrow(() => new prism.opus.Decoder({ rate: 48000, channels: 2, frameSize: 960 }));
});

test('ends sessions without usable audio without leaving a recovery marker', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pontograva-discord-empty-'));
  const hidden = join(root, '.discord');
  const clips = join(hidden, 'clips');
  mkdirSync(clips, { recursive: true });
  writeFileSync(join(clips, 'empty.pcm'), '');
  const sessionPath = join(hidden, 'session.json');
  writeJSONAtomic(sessionPath, {
    version: 1,
    status: 'finalizing',
    guildId: 'guild',
    guildName: 'Servidor',
    channelId: 'channel',
    channelName: 'Geral',
    startedAt: new Date().toISOString(),
    durationSeconds: 4,
    clips: [{ userId: '1', displayName: 'Ana', offsetMs: 0, path: 'clips/empty.pcm' }]
  });

  await assert.rejects(finalizeSession(root), /Nenhum áudio foi recebido/);
  assert.equal(existsSync(sessionPath), false);
  assert.equal(existsSync(root), true);
  rmSync(root, { recursive: true, force: true });
});

test('finalizes aligned participant tracks and mixed wav', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pontograva-discord-'));
  const hidden = join(root, '.discord');
  const clips = join(hidden, 'clips');
  mkdirSync(clips, { recursive: true });
  const ffmpeg = locateFFmpeg();
  for (const name of ['a.ogg', 'b.ogg']) {
    const result = spawnSync(ffmpeg, [
      '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.25',
      '-c:a', 'libopus', join(clips, name)
    ]);
    assert.equal(result.status, 0, result.stderr?.toString());
  }
  const pcm = spawnSync(ffmpeg, [
    '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=880:duration=0.25',
    '-f', 's16le', '-ar', '48000', '-ac', '2', join(clips, 'c.pcm')
  ]);
  assert.equal(pcm.status, 0, pcm.stderr?.toString());
  writeFileSync(join(clips, 'empty.pcm'), '');
  writeJSONAtomic(join(hidden, 'session.json'), {
    version: 1,
    status: 'finalizing',
    guildId: 'guild',
    guildName: 'Servidor',
    channelId: 'channel',
    channelName: 'Geral',
    startedAt: new Date().toISOString(),
    durationSeconds: 2,
    clips: [
      { userId: '1', displayName: 'Ana', offsetMs: 0, path: 'clips/a.ogg' },
      { userId: '1', displayName: 'Ana', offsetMs: 750, path: 'clips/b.ogg' },
      { userId: '1', displayName: 'Ana', offsetMs: 1_250, format: 's16le', path: 'clips/empty.pcm' },
      { userId: '2', displayName: 'Beto', offsetMs: 250, format: 's16le', path: 'clips/c.pcm' }
    ]
  });

  const result = await finalizeSession(root, ffmpeg);
  assert.equal(result.version, 2);
  assert.equal(result.participants.length, 2);
  assert.equal(result.captureDiagnostics.participants[0].displayName, 'Ana');
  assert.equal(result.captureDiagnostics.participants[0].emptyClips, 1);
  assert.ok(existsSync(result.audioPath));
  assert.ok(existsSync(result.manifestPath));
  assert.ok(statSync(result.audioPath).size < 1_000_000);
  assert.equal(JSON.parse(readFileSync(result.manifestPath, 'utf8')).version, 2);
  assert.ok(!existsSync(join(hidden, 'session.json')));
  rmSync(root, { recursive: true, force: true });
});

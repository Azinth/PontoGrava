import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Readable } from 'node:stream';
import prism from 'prism-media';
import {
  AudioLevelReporter,
  createPCMLevelMeter,
  finalizeSession,
  locateFFmpeg,
  normalizedPCMLevel,
  participantFilter,
  safeName,
  writeJSONAtomic
} from './audio.js';

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

test('sanitizes participant ids used as filenames', () => {
  assert.equal(safeName('../user:42'), '.._user_42');
});

test('aligns overlapping clips before mixing', () => {
  const filter = participantFilter([{ offsetMs: 0 }, { offsetMs: 1250 }], 10);
  assert.match(filter, /\[0:a\]adelay=0:all=1/);
  assert.match(filter, /\[1:a\]adelay=1250:all=1/);
  assert.match(filter, /amix=inputs=2/);
  assert.match(filter, /atrim=duration=10\.000/);
});

test('loads the Opus decoder used for received voice packets', () => {
  assert.doesNotThrow(() => new prism.opus.Decoder({ rate: 48000, channels: 2, frameSize: 960 }));
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
      { userId: '2', displayName: 'Beto', offsetMs: 250, format: 's16le', path: 'clips/c.pcm' }
    ]
  });

  const result = await finalizeSession(root, ffmpeg);
  assert.equal(result.participants.length, 2);
  assert.ok(existsSync(result.audioPath));
  assert.ok(existsSync(result.manifestPath));
  assert.ok(!existsSync(join(hidden, 'session.json')));
  rmSync(root, { recursive: true, force: true });
});

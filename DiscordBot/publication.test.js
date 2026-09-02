import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ChannelType } from 'discord.js';
import {
  publicationChannelName,
  publicationChannelTopic,
  publicationMessageContent,
  publicationVoiceChannelId,
  publishMeeting,
  resolvePublicationChannel
} from './publication.js';

function voiceChannel(overrides = {}) {
  return {
    id: '123456789012345678',
    name: 'Reunião 1',
    type: ChannelType.GuildVoice,
    parentId: 'category',
    permissionOverwrites: {
      cache: new Map([['everyone', {
        id: 'everyone',
        type: 0,
        allow: { bitfield: 1n },
        deny: { bitfield: 2n }
      }]])
    },
    ...overrides
  };
}

function textChannel(overrides = {}) {
  const channel = {
    id: 'text',
    name: 'pontograva-reuniao-1',
    type: ChannelType.GuildText,
    parentId: 'category',
    topic: 'PontoGrava:voice-channel=123456789012345678',
    async edit(options) {
      channel.lastEdit = options;
      channel.name = options.name;
      channel.parentId = options.parent;
      channel.topic = options.topic;
      return channel;
    },
    ...overrides
  };
  return channel;
}

test('normalizes the text channel name and preserves the voice marker', () => {
  assert.equal(
    publicationChannelName('  Reunião #1 / Produto  ', '123456'),
    'pontograva-reuniao-1-produto'
  );
  const topic = publicationChannelTopic('Notas da equipe', '123456');
  assert.equal(publicationVoiceChannelId(topic), '123456');
  assert.match(topic, /^Notas da equipe\n/);
});

test('reuses and synchronizes the channel linked to the voice room', async () => {
  const voice = voiceChannel({ name: 'Reunião Renomeada', parentId: 'new-category' });
  const text = textChannel();
  const guild = {
    channels: {
      cache: new Map([[voice.id, voice], [text.id, text]])
    }
  };
  const result = await resolvePublicationChannel(guild, voice);
  assert.equal(result.id, text.id);
  assert.equal(text.lastEdit.name, 'pontograva-reuniao-renomeada');
  assert.equal(text.lastEdit.parent, 'new-category');
  assert.deepEqual(text.lastEdit.permissionOverwrites, [{
    id: 'everyone', type: 0, allow: 1n, deny: 2n
  }]);
});

test('creates one marked channel when no equivalent exists', async () => {
  const voice = voiceChannel();
  let creation;
  const guild = {
    channels: {
      cache: new Map([[voice.id, voice]]),
      async create(options) {
        creation = options;
        return { id: 'created', ...options };
      }
    }
  };
  const result = await resolvePublicationChannel(guild, voice);
  assert.equal(result.id, 'created');
  assert.equal(creation.name, 'pontograva-reuniao-1');
  assert.equal(creation.parent, 'category');
  assert.equal(publicationVoiceChannelId(creation.topic), voice.id);
});

test('refuses to guess between duplicate unmarked channels', async () => {
  const voice = voiceChannel();
  const first = textChannel({ id: 'first', topic: null });
  const second = textChannel({ id: 'second', topic: null });
  const guild = {
    channels: {
      cache: new Map([[voice.id, voice], [first.id, first], [second.id, second]])
    }
  };
  await assert.rejects(
    resolvePublicationChannel(guild, voice),
    /mais de um canal chamado pontograva-reuniao-1/
  );
});

test('formats a bounded message and points to the complete summary attachment', () => {
  const content = publicationMessageContent({
    title: 'Reunião',
    createdAt: '2026-09-02T12:00:00Z',
    voiceChannelId: '123',
    summary: 'a'.repeat(3_000)
  });
  assert.ok(Array.from(content).length <= 2_000);
  assert.match(content, /Resumo completo disponível em resumo\.md/);
});

test('updates the existing publication and replaces its attachments', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pontograva-publication-'));
  const transcript = join(root, 'transcricao.txt');
  const summary = join(root, 'resumo.md');
  writeFileSync(transcript, 'Transcrição');
  writeFileSync(summary, '# Resumo');
  try {
    const voice = voiceChannel();
    let editOptions;
    const message = {
      id: 'message',
      author: { id: 'bot' },
      async edit(options) {
        editOptions = options;
        return message;
      }
    };
    const text = textChannel({
      messages: { async fetch() { return message; } },
      async send() { throw new Error('should update instead of sending'); }
    });
    const guild = {
      channels: {
        cache: new Map([[voice.id, voice], [text.id, text]]),
        async fetch() { return voice; }
      }
    };
    const result = await publishMeeting({
      isReady: () => true,
      user: { id: 'bot' },
      guilds: { cache: new Map([['guild', guild]]) }
    }, {
      guildId: 'guild',
      voiceChannelId: voice.id,
      title: 'Reunião',
      createdAt: '2026-09-02T12:00:00Z',
      transcriptPath: transcript,
      summaryPath: summary,
      textChannelId: text.id,
      messageId: message.id
    });
    assert.deepEqual(result, { textChannelId: text.id, messageId: message.id });
    assert.deepEqual(editOptions.attachments, []);
    assert.deepEqual(editOptions.files.map(file => file.name), ['transcricao.txt', 'resumo.md']);
    assert.deepEqual(editOptions.allowedMentions, { parse: [] });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

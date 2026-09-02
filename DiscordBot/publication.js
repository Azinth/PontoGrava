import { readFile } from 'node:fs/promises';
import { ChannelType } from 'discord.js';

const markerPrefix = 'PontoGrava:voice-channel=';
const maximumChannelNameLength = 100;
const maximumMessageLength = 2_000;
const maximumTopicLength = 1_024;

export function publicationChannelName(voiceName, voiceChannelId) {
  const slug = voiceName
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') || `canal-${voiceChannelId.slice(-6)}`;
  return `pontograva-${slug}`.slice(0, maximumChannelNameLength).replace(/-+$/g, '');
}

export function publicationVoiceChannelId(topic) {
  const marker = String(topic ?? '')
    .split('\n')
    .find(line => line.startsWith(markerPrefix));
  return marker?.slice(markerPrefix.length) || null;
}

export function publicationChannelTopic(topic, voiceChannelId) {
  const marker = `${markerPrefix}${voiceChannelId}`;
  const description = String(topic ?? '')
    .split('\n')
    .filter(line => !line.startsWith(markerPrefix))
    .join('\n')
    .trim();
  if (!description) return marker;
  const available = maximumTopicLength - marker.length - 1;
  return `${Array.from(description).slice(0, available).join('')}\n${marker}`;
}

function permissionOverwrites(channel) {
  return [...channel.permissionOverwrites.cache.values()].map(overwrite => ({
    id: overwrite.id,
    type: overwrite.type,
    allow: overwrite.allow.bitfield,
    deny: overwrite.deny.bitfield
  }));
}

function textChannels(guild) {
  return [...guild.channels.cache.values()]
    .filter(channel => channel.type === ChannelType.GuildText);
}

export async function resolvePublicationChannel(guild, voiceChannel, preferredChannelId = null) {
  const channels = textChannels(guild);
  const expectedName = publicationChannelName(voiceChannel.name, voiceChannel.id);
  let target = preferredChannelId
    ? channels.find(channel => channel.id === preferredChannelId) ?? null
    : null;

  if (target && ![null, voiceChannel.id].includes(publicationVoiceChannelId(target.topic))) {
    target = null;
  }

  if (!target) {
    const marked = channels.filter(channel => publicationVoiceChannelId(channel.topic) === voiceChannel.id);
    if (marked.length > 1) {
      throw new Error(`Há mais de um canal de texto vinculado à sala ${voiceChannel.name}.`);
    }
    target = marked[0] ?? null;
  }

  if (!target) {
    const matching = channels.filter(channel =>
      channel.parentId === voiceChannel.parentId
      && channel.name === expectedName
      && publicationVoiceChannelId(channel.topic) === null
    );
    if (matching.length > 1) {
      throw new Error(`Há mais de um canal chamado ${expectedName} na categoria da sala.`);
    }
    target = matching[0] ?? null;
  }

  const overwritePayload = permissionOverwrites(voiceChannel);
  if (!target) {
    const nameIsUsedByAnotherRoom = channels.some(channel =>
      channel.name === expectedName
      && publicationVoiceChannelId(channel.topic) !== null
      && publicationVoiceChannelId(channel.topic) !== voiceChannel.id
    );
    const suffix = `-${voiceChannel.id.slice(-6)}`;
    const name = nameIsUsedByAnotherRoom
      ? `${expectedName.slice(0, maximumChannelNameLength - suffix.length)}${suffix}`
      : expectedName;
    return guild.channels.create({
      name,
      type: ChannelType.GuildText,
      parent: voiceChannel.parentId,
      topic: publicationChannelTopic('', voiceChannel.id),
      permissionOverwrites: overwritePayload,
      reason: `Publicações do PontoGrava para ${voiceChannel.name}`
    });
  }

  return target.edit({
    name: expectedName,
    parent: voiceChannel.parentId,
    lockPermissions: false,
    topic: publicationChannelTopic(target.topic, voiceChannel.id),
    permissionOverwrites: overwritePayload,
    reason: `Sincronização do PontoGrava com ${voiceChannel.name}`
  });
}

export function publicationMessageContent({ title, createdAt, voiceChannelId, summary }) {
  const timestamp = Math.floor(Date.parse(createdAt) / 1_000);
  const metadata = [
    `## ${title}`,
    `Sala de voz: <#${voiceChannelId}>`,
    Number.isFinite(timestamp) ? `Gravada em: <t:${timestamp}:F>` : null
  ].filter(Boolean).join('\n');
  if (!summary?.trim()) return metadata;

  const separator = '\n\n';
  const overflowNote = '\n\n_Resumo completo disponível em resumo.md._';
  const available = maximumMessageLength - metadata.length - separator.length;
  if (Array.from(summary).length <= available) return `${metadata}${separator}${summary.trim()}`;
  const shortened = Array.from(summary.trim())
    .slice(0, Math.max(0, available - overflowNote.length))
    .join('')
    .trimEnd();
  return `${metadata}${separator}${shortened}${overflowNote}`;
}

function isUnknownMessage(error) {
  return error?.code === 10_008 || error?.rawError?.code === 10_008;
}

export async function publishMeeting(client, command) {
  if (!client.isReady()) throw new Error('Conecte o bot antes de publicar a reunião.');
  const guild = client.guilds.cache.get(command.guildId);
  if (!guild) throw new Error('Servidor da reunião não encontrado para este bot.');
  const voiceChannel = guild.channels.cache.get(command.voiceChannelId)
    ?? await guild.channels.fetch(command.voiceChannelId);
  if (!voiceChannel || voiceChannel.type !== ChannelType.GuildVoice) {
    throw new Error('O canal de voz original da reunião não existe mais.');
  }

  const channel = await resolvePublicationChannel(
    guild,
    voiceChannel,
    command.textChannelId ?? null
  );
  const summary = command.summaryPath
    ? await readFile(command.summaryPath, 'utf8')
    : null;
  const content = publicationMessageContent({
    title: command.title,
    createdAt: command.createdAt,
    voiceChannelId: voiceChannel.id,
    summary
  });
  const files = [
    { attachment: command.transcriptPath, name: 'transcricao.txt' },
    ...(command.summaryPath ? [{ attachment: command.summaryPath, name: 'resumo.md' }] : [])
  ];
  const options = {
    content,
    files,
    allowedMentions: { parse: [] }
  };

  let message = null;
  if (command.messageId && command.textChannelId === channel.id) {
    try {
      const existing = await channel.messages.fetch(command.messageId);
      if (existing.author.id !== client.user.id) {
        throw new Error('A publicação registrada não pertence ao bot do PontoGrava.');
      }
      message = await existing.edit({ ...options, attachments: [] });
    } catch (error) {
      if (!isUnknownMessage(error)) throw error;
    }
  }
  if (!message) message = await channel.send(options);

  return { textChannelId: channel.id, messageId: message.id };
}

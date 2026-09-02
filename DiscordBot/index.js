import { createWriteStream, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { pipeline } from 'node:stream';
import {
  EndBehaviorType,
  VoiceConnectionStatus,
  entersState,
  joinVoiceChannel
} from '@discordjs/voice';
import {
  ChannelType,
  Client,
  GatewayIntentBits
} from 'discord.js';
import prism from 'prism-media';
import { publishMeeting } from './publication.js';
import {
  AudioLevelReporter,
  SpeakerCaptureCoordinator,
  createPCMLevelMeter,
  finalizeSession,
  locateFFmpeg,
  markClipFirstPacket,
  readSession,
  recordingCommandError,
  safeName,
  startRecordingCommandError,
  terminateRunningCommands,
  writeJSONAtomic
} from './audio.js';

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates]
});
const ffmpegPath = locateFFmpeg();
let recording = null;
const finalizations = new Map();

async function finalizeOnce(folderPath) {
  if (finalizations.has(folderPath)) {
    throw new Error('Esta gravação já está sendo finalizada.');
  }
  const task = finalizeSession(folderPath, ffmpegPath);
  finalizations.set(folderPath, task);
  try {
    return await task;
  } finally {
    finalizations.delete(folderPath);
  }
}
let pendingStart = null;
let emptyTimer = null;
let isShuttingDown = false;
const recordingCommands = [
  { name: 'start', description: 'Inicia a gravação do canal de voz atual com o PontoGrava.' },
  { name: 'stop', description: 'Encerra e finaliza a gravação ativa do PontoGrava.' }
];
const recordingCommandNames = new Set(recordingCommands.map(command => command.name));
const removedRecordingCommandNames = new Set(['pause', 'resume']);

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function reply(id, result) {
  emit({ type: 'response', id, ok: true, result });
}

function fail(id, error) {
  emit({ type: 'response', id, ok: false, message: error?.message ?? String(error) });
}

function event(name, result = {}) {
  emit({ type: 'event', event: name, result });
}

async function ensureGuildCommands(guild) {
  const existing = await guild.commands.fetch();
  await Promise.all(
    existing
      .filter(command => removedRecordingCommandNames.has(command.name))
      .map(command => command.delete())
  );
  for (const command of recordingCommands) {
    const registered = existing.find(item => item.name === command.name);
    if (registered) await registered.edit(command);
    else await guild.commands.create(command);
  }
}

async function connect(token) {
  if (!client.isReady()) {
    await client.login(token);
    if (!client.isReady()) await new Promise(resolve => client.once('ready', resolve));
  }
  await Promise.all([...client.guilds.cache.values()].map(ensureGuildCommands));
  return { applicationId: client.user.id, username: client.user.username };
}

function guilds() {
  return [...client.guilds.cache.values()]
    .map(guild => ({ id: guild.id, name: guild.name }))
    .sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'));
}

function channels(guildId) {
  const guild = client.guilds.cache.get(guildId);
  if (!guild) throw new Error('Servidor não encontrado para este bot.');
  return [...guild.channels.cache.values()]
    .filter(channel => channel.type === ChannelType.GuildVoice)
    .map(channel => ({ id: channel.id, name: channel.name }))
    .sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'));
}

function persistSession(current = recording) {
  if (!current) return;
  writeJSONAtomic(current.sessionPath, current.session);
}

function participantDiagnostics(current, userId, displayName = null) {
  let participant = current.session.captureDiagnostics.participants
    .find(item => item.userId === userId);
  if (!participant) {
    participant = {
      userId,
      displayName: displayName ?? userId,
      automaticRestarts: 0,
      streamErrors: 0,
      emptyClips: 0
    };
    current.session.captureDiagnostics.participants.push(participant);
  } else if (displayName) {
    participant.displayName = displayName;
  }
  return participant;
}

function beginSpeakerCapture(current, userId, { markEnding }) {
  const member = current.guild.members.cache.get(userId);
  const displayName = member?.displayName ?? member?.user?.username ?? userId;
  participantDiagnostics(current, userId, displayName);
  const index = current.session.clips.length + 1;
  const clip = {
    userId,
    displayName,
    offsetMs: null,
    format: 's16le',
    path: `clips/${safeName(userId)}-${String(index).padStart(5, '0')}.pcm`
  };
  current.session.clips.push(clip);
  persistSession(current);

  const opus = current.connection.receiver.subscribe(userId, {
    end: { behavior: EndBehaviorType.AfterSilence, duration: 250 }
  });
  opus.once('data', () => {
    if (markClipFirstPacket(clip, current.session.startedAt)) persistSession(current);
  });
  opus.once('end', markEnding);
  opus.once('close', markEnding);
  opus.once('error', markEnding);
  const decoder = new prism.opus.Decoder({ rate: 48000, channels: 2, frameSize: 960 });
  const meter = createPCMLevelMeter(level => {
    if (recording === current) current.audioLevels.update(userId, level);
  });
  const output = createWriteStream(join(current.hiddenPath, clip.path));
  event('participant', { userId, displayName });

  return new Promise((resolve, reject) => {
    pipeline(opus, decoder, meter, output, error => {
      markEnding();
      clip.endedOffsetMs = Date.now() - Date.parse(current.session.startedAt);
      if (recording === current) persistSession(current);
      current.audioLevels.remove(userId);
      if (error) reject(error);
      else resolve();
    });
  });
}

function recordSpeaker(userId) {
  const current = recording;
  if (!current || userId === client.user.id) return;
  current.captureCoordinator.request(userId);
}

function scheduleEmptyStop() {
  if (!recording) return;
  const humans = recording.channel.members.filter(member => !member.user.bot).size;
  if (humans > 0) {
    clearTimeout(emptyTimer);
    emptyTimer = null;
    return;
  }
  if (emptyTimer) return;
  emptyTimer = setTimeout(() => {
    stopRecording('empty').then(result => event('recordingStopped', result))
      .catch(error => event('recordingFailed', { message: error.message }));
  }, 60_000);
}

async function startRecording(command) {
  if (recording) throw new Error('Já existe uma gravação do Discord em andamento.');
  if (command.requestId && command.requestId !== pendingStart?.id) {
    throw new Error('A solicitação de início não está mais ativa.');
  }
  if (!command.requestId && pendingStart) {
    throw new Error('Outra gravação do Discord já está sendo iniciada.');
  }
  if (!client.isReady()) throw new Error('Conecte o bot antes de iniciar.');
  const guild = client.guilds.cache.get(command.guildId);
  const channel = guild?.channels.cache.get(command.channelId);
  if (!guild || !channel || channel.type !== ChannelType.GuildVoice) {
    throw new Error('Canal de voz não encontrado.');
  }

  const hiddenPath = join(command.folderPath, '.discord');
  mkdirSync(join(hiddenPath, 'clips'), { recursive: true });
  const session = {
    version: 2,
    status: 'recording',
    guildId: guild.id,
    guildName: guild.name,
    channelId: channel.id,
    channelName: channel.name,
    startedAt: new Date().toISOString(),
    clips: [],
    captureDiagnostics: { participants: [] }
  };
  const connection = joinVoiceChannel({
    channelId: channel.id,
    guildId: guild.id,
    adapterCreator: guild.voiceAdapterCreator,
    selfDeaf: false,
    selfMute: true
  });
  connection.on('error', error => {
    process.stderr.write(`Discord voice: ${error.stack ?? error.message}\n`);
    if (recording?.connection === connection) {
      stopRecording('voice-error').then(result => event('recordingStopped', result))
        .catch(stopError => event('recordingFailed', { message: stopError.message }));
    }
  });
  try {
    await entersState(connection, VoiceConnectionStatus.Ready, 20_000);
  } catch (error) {
    connection.destroy();
    throw error;
  }

  const current = {
    folderPath: command.folderPath,
    hiddenPath,
    sessionPath: join(hiddenPath, 'session.json'),
    session,
    guild,
    channel,
    connection,
    audioLevels: new AudioLevelReporter(level => event('audioLevel', { level }))
  };
  current.captureCoordinator = new SpeakerCaptureCoordinator({
    beginCapture: (userId, state) => beginSpeakerCapture(current, userId, state),
    isSpeaking: userId => connection.receiver.speaking.users.has(userId),
    onError: (userId, error) => {
      participantDiagnostics(current, userId).streamErrors += 1;
      persistSession(current);
      process.stderr.write(`Discord clip: ${error.message}\n`);
    },
    onRestart: userId => {
      participantDiagnostics(current, userId).automaticRestarts += 1;
      persistSession(current);
    }
  });
  recording = current;
  persistSession(current);
  connection.receiver.speaking.on('start', recordSpeaker);
  connection.on(VoiceConnectionStatus.Disconnected, () => {
    if (!recording) return;
    stopRecording('disconnected').then(result => event('recordingStopped', result))
      .catch(error => event('recordingFailed', { message: error.message }));
  });
  if (typeof channel.send === 'function') {
    try {
      await channel.send('🔴 O PontoGrava iniciou a gravação desta reunião.');
    } catch (error) {
      connection.receiver.speaking.off('start', recordSpeaker);
      recording = null;
      current.captureCoordinator.stop();
      current.audioLevels.reset();
      connection.destroy();
      await current.captureCoordinator.settle();
      throw new Error(`O bot entrou no canal, mas não pôde publicar o aviso: ${error.message}`);
    }
  }
  scheduleEmptyStop();
  return { ...session, folderPath: command.folderPath };
}

async function stopRecording(reason = 'manual', announce = true) {
  const current = recording;
  if (!current) throw new Error('Não há gravação do Discord em andamento.');
  recording = null;
  current.captureCoordinator.stop();
  clearTimeout(emptyTimer);
  emptyTimer = null;
  current.audioLevels.reset();
  current.connection.receiver.speaking.off('start', recordSpeaker);
  current.connection.destroy();
  await current.captureCoordinator.settle();
  current.session.status = 'finalizing';
  current.session.durationSeconds = Math.max(0.1, (Date.now() - Date.parse(current.session.startedAt)) / 1000);
  writeJSONAtomic(current.sessionPath, current.session);
  const result = await finalizeOnce(current.folderPath);
  if (announce && typeof current.channel.send === 'function') {
    try {
      await current.channel.send(`⏹️ O PontoGrava encerrou a gravação (${reason}).`);
    } catch (error) {
      process.stderr.write(`Discord notice: ${error.message}\n`);
    }
  }
  return result;
}

function memberName(interaction) {
  return interaction.member?.displayName ?? interaction.user.globalName ?? interaction.user.username;
}

async function rejectInteraction(interaction, message) {
  await interaction.reply({ content: message, ephemeral: true });
}

async function finishStartRequest(requestId, message) {
  if (!pendingStart || pendingStart.id !== requestId) return;
  const interaction = pendingStart.interaction;
  pendingStart = null;
  try {
    await interaction.editReply(message);
  } catch (error) {
    process.stderr.write(`Discord /start reply: ${error.message}\n`);
  }
}

async function handleStartInteraction(interaction) {
  const validationError = startRecordingCommandError(
    recording,
    pendingStart,
    interaction.channelId,
    interaction.member?.voice?.channelId
  );
  if (validationError) {
    await rejectInteraction(interaction, validationError);
    return;
  }

  pendingStart = { id: interaction.id, interaction };
  try {
    await interaction.deferReply({ ephemeral: true });
  } catch (error) {
    if (pendingStart?.id === interaction.id) pendingStart = null;
    throw error;
  }
  event('recordingStartRequested', {
    requestId: interaction.id,
    guildId: interaction.guildId,
    channelId: interaction.channelId
  });
}

async function handleStopInteraction(interaction) {
  const validationError = recordingCommandError(
    recording,
    interaction.guildId,
    interaction.channelId
  );
  if (validationError) {
    await rejectInteraction(interaction, validationError);
    return;
  }

  const displayName = memberName(interaction);
  const current = recording;
  current.stopping = true;
  try {
    await interaction.reply(`⏹️ ${displayName} encerrou a gravação. Finalizando…`);
  } catch (error) {
    if (recording === current) current.stopping = false;
    throw error;
  }
  try {
    const result = await stopRecording('comando /stop', false);
    event('recordingStopped', result);
    await interaction.editReply(`⏹️ ${displayName} encerrou a gravação.`);
  } catch (error) {
    event('recordingFailed', { message: error.message });
    await interaction.editReply('⚠️ Não foi possível finalizar a gravação. Verifique o PontoGrava no Mac.');
  }
}

async function handleInteraction(interaction) {
  if (!interaction.isChatInputCommand() || !recordingCommandNames.has(interaction.commandName)) return;
  if (interaction.commandName === 'start') await handleStartInteraction(interaction);
  else await handleStopInteraction(interaction);
}

client.on('voiceStateUpdate', (oldState, newState) => {
  if (!recording) return;
  if (oldState.channelId === recording.channel.id || newState.channelId === recording.channel.id) {
    scheduleEmptyStop();
  }
});
client.on('interactionCreate', interaction => {
  handleInteraction(interaction).catch(error => process.stderr.write(`Discord command: ${error.message}\n`));
});
client.on('guildCreate', guild => {
  ensureGuildCommands(guild).catch(error => process.stderr.write(`Discord commands: ${error.message}\n`));
});

async function handle(command) {
  switch (command.command) {
  case 'connect': return connect(command.token);
  case 'listGuilds': return { guilds: guilds() };
  case 'listChannels': return { channels: channels(command.guildId) };
  case 'start': {
    try {
      const result = await startRecording(command);
      if (command.requestId) {
        await finishStartRequest(command.requestId, '🔴 Gravação iniciada neste canal.');
      }
      return result;
    } catch (error) {
      if (command.requestId) {
        await finishStartRequest(
          command.requestId,
          '⚠️ Não foi possível iniciar a gravação. Verifique o PontoGrava no Mac.'
        );
      }
      throw error;
    }
  }
  case 'rejectStart':
    await finishStartRequest(command.requestId, command.message);
    return {};
  case 'stop': return stopRecording('manual');
  case 'recover': {
    const session = readSession(command.folderPath);
    session.status = 'finalizing';
    writeJSONAtomic(join(command.folderPath, '.discord', 'session.json'), session);
    return finalizeOnce(command.folderPath);
  }
  case 'publishMeeting': return publishMeeting(client, command);
  default: throw new Error(`Comando desconhecido: ${command.command}`);
  }
}

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', async line => {
  let command;
  try {
    command = JSON.parse(line);
    reply(command.id, await handle(command));
  } catch (error) {
    fail(command?.id ?? '', error);
  }
});

async function shutdown() {
  if (isShuttingDown) return;
  isShuttingDown = true;
  try {
    if (recording) await stopRecording('app fechado');
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
  } finally {
    terminateRunningCommands();
    client.destroy();
    process.exit(0);
  }
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
lines.on('close', shutdown);

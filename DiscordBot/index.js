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
import {
  AudioLevelReporter,
  createPCMLevelMeter,
  finalizeSession,
  locateFFmpeg,
  readSession,
  safeName,
  writeJSONAtomic
} from './audio.js';

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates]
});
const ffmpegPath = locateFFmpeg();
let recording = null;
let emptyTimer = null;
let isShuttingDown = false;

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

async function connect(token) {
  if (client.isReady()) return { applicationId: client.user.id, username: client.user.username };
  await client.login(token);
  if (!client.isReady()) await new Promise(resolve => client.once('ready', resolve));
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

function persistSession() {
  if (!recording) return;
  writeJSONAtomic(recording.sessionPath, recording.session);
}

function recordSpeaker(userId) {
  if (!recording || userId === client.user.id || recording.activeUsers.has(userId)) return;
  try {
    const current = recording;
    const member = current.guild.members.cache.get(userId);
    const displayName = member?.displayName ?? member?.user?.username ?? userId;
    const offsetMs = Date.now() - Date.parse(current.session.startedAt);
    const index = current.session.clips.length + 1;
    const clip = {
      userId,
      displayName,
      offsetMs,
      format: 's16le',
      path: `clips/${safeName(userId)}-${String(index).padStart(5, '0')}.pcm`
    };
    current.session.clips.push(clip);
    persistSession();

    const opus = current.connection.receiver.subscribe(userId, {
      end: { behavior: EndBehaviorType.AfterSilence, duration: 250 }
    });
    const decoder = new prism.opus.Decoder({ rate: 48000, channels: 2, frameSize: 960 });
    const meter = createPCMLevelMeter(level => {
      if (recording === current) current.audioLevels.update(userId, level);
    });
    const output = createWriteStream(join(current.hiddenPath, clip.path));
    current.activeUsers.add(userId);
    const finished = new Promise(resolve => {
      pipeline(opus, decoder, meter, output, error => {
        clip.endedOffsetMs = Date.now() - Date.parse(current.session.startedAt);
        if (recording === current) persistSession();
        current.activeUsers.delete(userId);
        current.audioLevels.remove(userId);
        if (error) process.stderr.write(`Discord clip: ${error.message}\n`);
        resolve();
      });
    });
    current.pipelines.add(finished);
    finished.finally(() => current.pipelines.delete(finished));
    event('participant', { userId, displayName });
  } catch (error) {
    process.stderr.write(`Discord receiver: ${error.stack ?? error.message}\n`);
    stopRecording('receiver-error').then(result => event('recordingStopped', result))
      .catch(() => event('recordingFailed', { message: `Não foi possível receber o áudio: ${error.message}` }));
  }
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
  if (!client.isReady()) throw new Error('Conecte o bot antes de iniciar.');
  const guild = client.guilds.cache.get(command.guildId);
  const channel = guild?.channels.cache.get(command.channelId);
  if (!guild || !channel || channel.type !== ChannelType.GuildVoice) {
    throw new Error('Canal de voz não encontrado.');
  }

  const hiddenPath = join(command.folderPath, '.discord');
  mkdirSync(join(hiddenPath, 'clips'), { recursive: true });
  const session = {
    version: 1,
    status: 'recording',
    guildId: guild.id,
    guildName: guild.name,
    channelId: channel.id,
    channelName: channel.name,
    startedAt: new Date().toISOString(),
    clips: []
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

  recording = {
    folderPath: command.folderPath,
    hiddenPath,
    sessionPath: join(hiddenPath, 'session.json'),
    session,
    guild,
    channel,
    connection,
    activeUsers: new Set(),
    pipelines: new Set(),
    audioLevels: new AudioLevelReporter(level => event('audioLevel', { level }))
  };
  persistSession();
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
      recording.audioLevels.reset();
      connection.destroy();
      recording = null;
      throw new Error(`O bot entrou no canal, mas não pôde publicar o aviso: ${error.message}`);
    }
  }
  scheduleEmptyStop();
  return { ...session, folderPath: command.folderPath };
}

async function stopRecording(reason = 'manual') {
  const current = recording;
  if (!current) throw new Error('Não há gravação do Discord em andamento.');
  recording = null;
  clearTimeout(emptyTimer);
  emptyTimer = null;
  current.audioLevels.reset();
  current.connection.receiver.speaking.off('start', recordSpeaker);
  current.connection.destroy();
  await Promise.allSettled([...current.pipelines]);
  current.session.status = 'finalizing';
  current.session.durationSeconds = Math.max(0.1, (Date.now() - Date.parse(current.session.startedAt)) / 1000);
  writeJSONAtomic(current.sessionPath, current.session);
  const result = await finalizeSession(current.folderPath, ffmpegPath);
  if (typeof current.channel.send === 'function') {
    try {
      await current.channel.send(`⏹️ O PontoGrava encerrou a gravação (${reason}).`);
    } catch (error) {
      process.stderr.write(`Discord notice: ${error.message}\n`);
    }
  }
  return result;
}

client.on('voiceStateUpdate', (oldState, newState) => {
  if (!recording) return;
  if (oldState.channelId === recording.channel.id || newState.channelId === recording.channel.id) {
    scheduleEmptyStop();
  }
});

async function handle(command) {
  switch (command.command) {
  case 'connect': return connect(command.token);
  case 'listGuilds': return { guilds: guilds() };
  case 'listChannels': return { channels: channels(command.guildId) };
  case 'start': return startRecording(command);
  case 'stop': return stopRecording('manual');
  case 'recover': {
    const session = readSession(command.folderPath);
    session.status = 'finalizing';
    writeJSONAtomic(join(command.folderPath, '.discord', 'session.json'), session);
    return finalizeSession(command.folderPath, ffmpegPath);
  }
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
    client.destroy();
    process.exit(0);
  }
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
lines.on('close', shutdown);

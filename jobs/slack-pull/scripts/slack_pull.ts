#!/usr/bin/env npx tsx
/**
 * slack_pull.ts — Pull recent Slack DMs and mentions, output as JSON or markdown.
 *
 * Strategy: Uses search.messages to fetch DMs and mentions in 1-2 API calls
 * instead of iterating every DM channel. Results grouped by conversation.
 *
 * Usage: npx tsx slack_pull.ts [--hours N] [--dry-run] [--json]
 *
 * Config: Set SLACK_BOT_TOKEN, SLACK_USER_TOKEN, and SLACK_TEAM_ID in .env at repo root.
 * Watched channels listed in config.json (auto-created on first run).
 */

// Suppress dotenv v17 startup banner before importing
process.env.DOTENV_CONFIG_QUIET = "true";

import fs from "fs";
import path from "path";
import dotenv from "dotenv";

dotenv.config({ path: path.resolve(import.meta.dirname, "../../.env") });

// --- Types ---

interface Config {
  channels: string[];
  include_dms: boolean;
  include_mentions: boolean;
}

interface Message {
  user: string;
  time: string;
  text: string;
  ts: string;
  thread_ts?: string;
}

interface ConversationGroup {
  label: string;
  messages: Message[];
}

interface MentionMessage extends Message {
  channel: string;
}

interface JsonOutput {
  time_range: { from: string; to: string };
  dms: ConversationGroup[];
  mentions: MentionMessage[];
  channels: ConversationGroup[];
  sent: MentionMessage[];
}

interface SlackMessage {
  ts: string;
  text?: string;
  user?: string;
  username?: string;
  thread_ts?: string;
  channel?: {
    id: string;
    name: string;
    is_im?: boolean;
    is_mpim?: boolean;
    user?: string;
  };
}

interface SlackChannel {
  id: string;
  name: string;
}

// --- Constants ---

const CONFIG_PATH = path.join(import.meta.dirname, "config.json");
const CONTEXT_DIR = path.resolve(import.meta.dirname, "../context");
const STATE_PATH = path.join(import.meta.dirname, ".last_run");
const SLACK_API = "https://slack.com/api";

const USER_TOKEN = process.env.SLACK_USER_TOKEN!;
const BOT_TOKEN = process.env.SLACK_BOT_TOKEN!;

// --- Config ---

function loadConfig(): Config {
  if (!fs.existsSync(CONFIG_PATH)) {
    const defaults: Config = { channels: [], include_dms: true, include_mentions: true };
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(defaults, null, 2));
    return defaults;
  }
  return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
}

// --- State ---

function getLastRunTs(): string | null {
  if (fs.existsSync(STATE_PATH)) {
    return fs.readFileSync(STATE_PATH, "utf-8").trim();
  }
  return null;
}

function saveLastRunTs(ts: string): void {
  fs.writeFileSync(STATE_PATH, ts);
}

// --- Helpers ---

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function parseArgs() {
  const args = process.argv.slice(2);
  let hours = 24;
  let dryRun = false;
  let jsonOutput = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--hours" && args[i + 1]) hours = parseInt(args[i + 1], 10);
    if (args[i] === "--dry-run") dryRun = true;
    if (args[i] === "--json") jsonOutput = true;
  }
  return { hours, dryRun, jsonOutput };
}

function tsToDate(ts: string): Date {
  return new Date(parseFloat(ts) * 1000);
}

function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function formatTime(d: Date): string {
  return d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: true });
}

// --- Slack API ---

async function slackApi(method: string, params: Record<string, string>, token: string = USER_TOKEN): Promise<any> {
  const url = new URL(`${SLACK_API}/${method}`);
  for (const [k, v] of Object.entries(params)) {
    url.searchParams.set(k, v);
  }
  const res = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = await res.json();
  if (!data.ok) {
    throw new Error(`Slack API ${method} failed: ${data.error}`);
  }
  return data;
}

async function getMyUserId(): Promise<string> {
  const res = await slackApi("auth.test", {});
  return res.user_id;
}

const userCache: Record<string, string> = {};

async function getUserName(userId: string): Promise<string> {
  if (userCache[userId]) return userCache[userId];
  try {
    const res = await slackApi("users.info", { user: userId }, BOT_TOKEN);
    const name = res.user.real_name || res.user.name;
    userCache[userId] = name;
    return name;
  } catch {
    userCache[userId] = userId;
    return userId;
  }
}

const MAX_SEARCH_PAGES = 5;

async function searchMessages(query: string): Promise<SlackMessage[]> {
  const allMatches: SlackMessage[] = [];
  let page = 1;
  let totalPages = 1;
  let totalResults = 0;
  do {
    const res = await slackApi("search.messages", {
      query,
      sort: "timestamp",
      sort_dir: "asc",
      count: "200",
      page: String(page),
    });
    const matches = res.messages?.matches || [];
    allMatches.push(...matches);
    totalPages = res.messages?.paging?.pages || 1;
    totalResults = res.messages?.paging?.total || 0;
    page++;
    if (page <= totalPages && page <= MAX_SEARCH_PAGES) await sleep(3000);
  } while (page <= totalPages && page <= MAX_SEARCH_PAGES);

  if (totalPages > MAX_SEARCH_PAGES) {
    console.warn(`  Warning: Search "${query}" has ${totalResults} results across ${totalPages} pages, capped at ${MAX_SEARCH_PAGES} pages (${allMatches.length} fetched)`);
  }

  return allMatches;
}

async function resolveChannels(entries: string[]): Promise<Array<{ id: string; name: string }>> {
  const nameMap = new Map<string, string>();
  let cursor: string | undefined;
  do {
    const res = await slackApi("conversations.list", {
      types: "public_channel,private_channel",
      limit: "200",
      exclude_archived: "true",
      ...(cursor ? { cursor } : {}),
    });
    for (const ch of (res.channels || []) as SlackChannel[]) {
      nameMap.set(ch.name, ch.id);
    }
    cursor = res.response_metadata?.next_cursor;
    if (cursor) await sleep(1200);
  } while (cursor);

  const resolved: Array<{ id: string; name: string }> = [];
  for (const entry of entries) {
    const name = entry.replace(/^#/, "");
    if (/^[CG][A-Z0-9]+$/.test(name)) {
      resolved.push({ id: name, name: entry });
    } else if (nameMap.has(name)) {
      resolved.push({ id: nameMap.get(name)!, name });
    } else {
      console.warn(`  Warning: Channel "${entry}" not found, skipping`);
    }
  }
  return resolved;
}

async function getChannelHistory(channelId: string, oldest: string): Promise<SlackMessage[]> {
  const messages: SlackMessage[] = [];
  let cursor: string | undefined;
  do {
    const res = await slackApi("conversations.history", {
      channel: channelId,
      oldest,
      limit: "200",
      ...(cursor ? { cursor } : {}),
    });
    messages.push(...(res.messages || []));
    cursor = res.response_metadata?.next_cursor;
  } while (cursor);
  return messages.reverse();
}

// --- Grouping ---

interface ChannelGroup {
  name: string;
  is_im?: boolean;
  is_mpim?: boolean;
  messages: SlackMessage[];
}

function groupByChannel(matches: SlackMessage[]): Map<string, ChannelGroup> {
  const groups = new Map<string, ChannelGroup>();
  for (const msg of matches) {
    const chId = msg.channel?.id || "unknown";
    const chName = msg.channel?.name || chId;
    if (!groups.has(chId)) {
      groups.set(chId, { name: chName, is_im: msg.channel?.is_im, is_mpim: msg.channel?.is_mpim, messages: [] });
    }
    groups.get(chId)!.messages.push(msg);
  }
  return groups;
}

// --- Resolve user mentions in text ---

function resolveText(text: string): string {
  return (text || "").replace(/<@(\w+)>/g, (_, id) => `@${userCache[id] || id}`);
}

// --- Main ---

async function main() {
  const { hours, dryRun, jsonOutput } = parseArgs();
  const config = loadConfig();

  const lastRunTs = getLastRunTs();
  const maxLookbackTs = String((Date.now() - 24 * 3600 * 1000) / 1000);
  const fallbackTs = String((Date.now() - hours * 3600 * 1000) / 1000);
  // Use last run if available, but never look back more than 24 hours
  const oldest = lastRunTs
    ? String(Math.max(parseFloat(lastRunTs), parseFloat(maxLookbackTs)))
    : fallbackTs;
  const nowTs = String(Date.now() / 1000);

  // Slack's `after:` filter is exclusive, so subtract a day
  const oldestDate = tsToDate(oldest);
  oldestDate.setDate(oldestDate.getDate() - 1);
  const afterDate = formatDate(oldestDate);

  if (!jsonOutput) {
    console.log(`Pulling Slack messages since ${tsToDate(oldest).toISOString()}`);
  }

  const myUserId = await getMyUserId();

  const result: JsonOutput = {
    time_range: { from: tsToDate(oldest).toISOString(), to: new Date().toISOString() },
    dms: [],
    mentions: [],
    channels: [],
    sent: [],
  };

  // 1. DMs
  if (config.include_dms) {
    if (!jsonOutput) console.log("Searching DMs...");
    const dmMatches = await searchMessages(`is:dm after:${afterDate}`);
    if (!jsonOutput) console.log(`  Found ${dmMatches.length} DM messages`);

    const filtered = dmMatches.filter((m) => parseFloat(m.ts) >= parseFloat(oldest));
    const groups = groupByChannel(filtered);

    for (const [, group] of groups) {
      const messages: Message[] = [];
      for (const msg of group.messages) {
        const name = msg.username || (msg.user ? await getUserName(msg.user) : "unknown");
        messages.push({
          user: name,
          time: tsToDate(msg.ts).toISOString(),
          text: resolveText(msg.text || ""),
          ts: msg.ts,
          thread_ts: msg.thread_ts,
        });
      }

      let label: string;
      if (group.is_mpim) {
        label = `Group DM: ${group.name}`;
      } else if (group.is_im && group.messages[0]?.channel?.user) {
        const userName = await getUserName(group.messages[0].channel.user);
        label = `DM: ${userName}`;
      } else {
        label = `DM: ${group.name}`;
      }

      result.dms.push({ label, messages });
      if (!jsonOutput) console.log(`  ${label}: ${messages.length} messages`);
    }
  }

  // 2. Mentions
  if (config.include_mentions) {
    if (!jsonOutput) console.log("Searching mentions...");
    const mentionMatches = await searchMessages(`<@${myUserId}> after:${afterDate}`);
    const filtered = mentionMatches.filter(
      (m) => parseFloat(m.ts) >= parseFloat(oldest) && !m.channel?.is_im && !m.channel?.is_mpim
    );

    for (const msg of filtered) {
      const name = msg.username || (msg.user ? await getUserName(msg.user) : "unknown");
      result.mentions.push({
        user: name,
        time: tsToDate(msg.ts).toISOString(),
        text: resolveText(msg.text || ""),
        channel: `#${msg.channel?.name || "unknown"}`,
        ts: msg.ts,
        thread_ts: msg.thread_ts,
      });
    }
    if (!jsonOutput) console.log(`  Mentions: ${filtered.length}`);
  }

  // 2.5. Sent messages (user's outgoing activity)
  if (!jsonOutput) console.log("Searching sent messages...");
  const sentMatches = await searchMessages(`from:me after:${afterDate}`);
  const sentFiltered = sentMatches.filter(
    (m) => parseFloat(m.ts) >= parseFloat(oldest) && !m.channel?.is_im && !m.channel?.is_mpim
  );

  for (const msg of sentFiltered) {
    result.sent.push({
      user: await getUserName(myUserId),
      time: tsToDate(msg.ts).toISOString(),
      text: resolveText(msg.text || ""),
      channel: `#${msg.channel?.name || "unknown"}`,
      ts: msg.ts,
      thread_ts: msg.thread_ts,
    });
  }
  if (!jsonOutput) console.log(`  Sent: ${sentFiltered.length}`);

  // 3. Watched channels
  if (config.channels.length > 0) {
    if (!jsonOutput) console.log(`Resolving ${config.channels.length} watched channels...`);
    const resolved = await resolveChannels(config.channels);
    if (!jsonOutput) console.log(`  Resolved ${resolved.length} channels, fetching history...`);

    for (const ch of resolved) {
      try {
        const rawMessages = await getChannelHistory(ch.id, oldest);
        if (rawMessages.length === 0) continue;

        const messages: Message[] = [];
        for (const msg of rawMessages) {
          const name = await getUserName(msg.user || "unknown");
          messages.push({
            user: name,
            time: tsToDate(msg.ts).toISOString(),
            text: resolveText(msg.text || ""),
            ts: msg.ts,
            thread_ts: msg.thread_ts,
          });
        }

        result.channels.push({ label: `#${ch.name}`, messages });
        if (!jsonOutput) console.log(`  #${ch.name}: ${messages.length} messages`);
        await sleep(1200);
      } catch {
        if (!jsonOutput) console.warn(`  Warning: Could not fetch #${ch.name}, skipping`);
      }
    }
  }

  // --- Output ---
  const hasMessages = result.dms.length > 0 || result.mentions.length > 0 || result.channels.length > 0 || result.sent.length > 0;

  if (!hasMessages) {
    if (jsonOutput) {
      console.log(JSON.stringify(result));
    } else {
      console.log("No new messages found.");
    }
    if (!dryRun) saveLastRunTs(nowTs);
    return;
  }

  if (jsonOutput) {
    console.log(JSON.stringify(result));
    if (!dryRun) saveLastRunTs(nowTs);
    return;
  }

  // Markdown output (legacy mode)
  const today = formatDate(new Date());
  const timeRange = `${formatTime(tsToDate(oldest))} – ${formatTime(new Date())}`;
  let md = `# Slack Pull — ${today}\n\n`;
  md += `**Time range:** ${timeRange}\n\n`;

  for (const dm of result.dms) {
    md += `## ${dm.label} (${dm.messages.length})\n\n`;
    for (const m of dm.messages) {
      md += `- **${m.user}** (${formatTime(new Date(m.time))}): ${m.text}\n`;
    }
    md += "\n";
  }

  if (result.mentions.length > 0) {
    md += `## Mentions (${result.mentions.length})\n\n`;
    for (const m of result.mentions) {
      md += `- **${m.user}** in ${m.channel} (${formatTime(new Date(m.time))}): ${m.text}\n`;
    }
    md += "\n";
  }

  if (result.sent.length > 0) {
    md += `## Sent Messages (${result.sent.length})\n\n`;
    for (const m of result.sent) {
      md += `- **${m.user}** in ${m.channel} (${formatTime(new Date(m.time))}): ${m.text}\n`;
    }
    md += "\n";
  }

  for (const ch of result.channels) {
    md += `## ${ch.label} (${ch.messages.length})\n\n`;
    for (const m of ch.messages) {
      md += `- **${m.user}** (${formatTime(new Date(m.time))}): ${m.text}\n`;
    }
    md += "\n";
  }

  if (dryRun) {
    console.log("\n--- DRY RUN OUTPUT ---\n");
    console.log(md);
  } else {
    const filename = `${today}_slack.md`;
    const filepath = path.join(CONTEXT_DIR, filename);
    if (fs.existsSync(filepath)) {
      fs.appendFileSync(filepath, "\n---\n\n" + md);
    } else {
      fs.writeFileSync(filepath, md);
    }
    console.log(`\nSaved to ${filepath}`);
    saveLastRunTs(nowTs);
  }
}

main().catch((err) => {
  console.error("Error:", err.message);
  process.exit(1);
});

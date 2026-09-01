#!/usr/bin/env node
/**
 * dsh-monitor.js — 读取 DeepSeek Harness 会话记录，提取每次请求的真实用量
 * （inputTokens / outputTokens / cacheReadTokens），增量追加到日志文件。
 *
 * 用法: node dsh-monitor.js <usage.log 路径> [sessions 根目录]
 * 依赖: Node.js ≥ 22.19（内置 zstd）
 */
'use strict';
const { zstdDecompressSync } = require('node:zlib');
const fs = require('fs');
const path = require('path');

const logPath = process.argv[2];
if (!logPath) process.exit(1);
const sessionsRoot = process.argv[3] || (
  process.env.DSH_HOME
    ? path.join(process.env.DSH_HOME, 'sessions')
    : path.join(process.env.USERPROFILE || '.', '.dsh', 'sessions')
);
const statePath = path.join(path.dirname(logPath), 'dsh-state.json');

/* ---------------- zstd 多帧扫描（帧边界手动解析） ---------------- */
const ZSTD_MAGIC = 0xFD2FB528;
const FILE_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

function scanFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) break;
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) break;
    offset += 4;
    const d = buffer.readUInt8(offset++);
    const csf = d >>> 6;
    const ss = (d & 0x20) !== 0;
    const chk = (d & 0x04) !== 0;
    const df = d & 0x03;
    const db = df === 3 ? 4 : df;
    const csb = csf === 0 ? (ss ? 1 : 0) : (1 << csf);
    offset += (ss ? 0 : 1) + db + csb;
    for (;;) {
      if (buffer.length - offset < 3) return { frames };
      const bh = buffer.readUIntLE(offset, 3);
      offset += 3;
      const last = (bh & 1) !== 0;
      const bt = (bh >>> 1) & 3;
      const bs = bh >>> 3;
      offset += bt === 1 ? 1 : bs;
      if (last) break;
    }
    if (chk) offset += 4;
    frames.push({ start, end: offset });
  }
  return { frames };
}

function decodeNewFrames(file, fromFrame) {
  const buf = fs.readFileSync(file);
  if (!(buf.length >= 4 && buf.subarray(0, 4).equals(FILE_MAGIC))) {
    return { text: '', frames: 0 };
  }
  const { frames } = scanFrames(buf);
  const parts = [];
  for (let i = fromFrame; i < frames.length; i++) {
    try {
      parts.push(zstdDecompressSync(buf.subarray(frames[i].start, frames[i].end)).toString('utf8'));
    } catch (e) { /* 单帧解压失败则跳过 */ }
  }
  return { text: parts.join(''), frames: frames.length };
}

/* ---------------- 事件 → 请求记录 ---------------- */
function pad(n) { return String(n).padStart(2, '0'); }
function fmtTs(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
function summary(text, n) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) + '…' : s;
}

const PRICES = {
  'deepseek-chat': { inputMiss: 0.8, inputHit: 0.4, output: 2.0 },
  'deepseek-reasoner': { inputMiss: 4.0, inputHit: 1.0, output: 16.0 },
};
function priceFor(model) {
  return String(model || '').includes('reasoner')
    ? PRICES['deepseek-reasoner']
    : PRICES['deepseek-chat'];
}

function extractRecords(text) {
  const records = [];
  let lastUser = '';
  let lastUserTime = 0;
  let model = 'unknown';
  let lastCache = 0;   // DSH 的 cacheReadTokens 是会话累计值，用差值算本次命中
  const seen = new Set();
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    const t = ev.type;
    if (t === 'user/message') {
      try {
        const content = ev.data?.content || [];
        const txt = content.filter(b => b.type === 'text').map(b => b.text).join(' ').trim();
        if (txt) { lastUser = txt; lastUserTime = ev.time || lastUserTime; }
      } catch { }
    } else if (t === 'request/header') {
      model = ev.data?.header?.config?.model || model;
    } else if (t === 'assistant/message') {
      const usage = ev.data?.usage;
      if (!usage || seen.has(ev.seq)) continue;
      seen.add(ev.seq);
      const input = usage.inputTokens || 0;          // 本次非缓存输入
      const output = usage.outputTokens || 0;
      const cacheTotal = usage.cacheReadTokens || 0; // 会话累计缓存
      const cacheHit = Math.max(0, cacheTotal - lastCache);
      lastCache = cacheTotal;
      const promptTokens = input + cacheHit;
      const p = priceFor(model);
      const cost = (input / 1e6) * p.inputMiss + (cacheHit / 1e6) * p.inputHit + (output / 1e6) * p.output;
      records.push({
        ts: fmtTs(ev.time || Date.now()),
        model,
        prompt: summary(lastUser, 24),
        prompt_tokens: promptTokens,
        completion_tokens: output,
        total_tokens: promptTokens + output,
        cache_hit: cacheHit,
        cache_miss: input,
        ratio: promptTokens > 0 ? Math.round((cacheHit / promptTokens) * 10000) / 10000 : null,
        cost: Math.round(cost * 1e6) / 1e6,
        elapsed_ms: lastUserTime ? Math.max(0, (ev.time || 0) - lastUserTime) : 0,
        source: 'dsh',
      });
    }
  }
  return records;
}

/* ---------------- 主流程（增量） ---------------- */
function main() {
  if (!fs.existsSync(sessionsRoot)) process.exit(0);
  // 会话文件在两层目录下：sessions/<工作目录>/<会话ID>/session.jsonl.zstd
  let latest = null;
  for (const name of fs.readdirSync(sessionsRoot)) {
    const wsDir = path.join(sessionsRoot, name);
    let st;
    try { st = fs.statSync(wsDir); } catch { continue; }
    if (!st.isDirectory()) continue;
    for (const sname of fs.readdirSync(wsDir)) {
      const f = path.join(wsDir, sname, 'session.jsonl.zstd');
      if (!fs.existsSync(f)) continue;
      const fst = fs.statSync(f);
      if (!latest || fst.mtimeMs > latest.mtimeMs) {
        latest = { file: f, mtimeMs: fst.mtimeMs };
      }
    }
  }
  if (!latest) process.exit(0);

  let state = { file: '', frames: 0 };
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { }

  const fromFrame = state.file === latest.file ? state.frames : 0;
  const { text, frames } = decodeNewFrames(latest.file, fromFrame);
  if (!text || frames <= (state.file === latest.file ? state.frames : -1)) process.exit(0);

  const records = extractRecords(text);
  if (records.length > 0) {
    fs.appendFileSync(logPath, records.map(r => JSON.stringify(r)).join('\n') + '\n', 'utf8');
  }
  try {
    fs.writeFileSync(statePath, JSON.stringify({ file: latest.file, frames }), 'utf8');
  } catch { }
}

main();

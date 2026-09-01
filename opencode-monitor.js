#!/usr/bin/env node
/**
 * opencode-monitor.js — 读取 OpenCode CLI 用量（opencode.db message 表），
 * 增量追加到日志。
 *
 * 用法: node opencode-monitor.js <usage.log 路径> [opencode 数据目录]
 * 依赖: Node.js ≥ 22.5（node:sqlite）
 */
'use strict';
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const path = require('path');

const logPath = process.argv[2];
if (!logPath) process.exit(1);
// 多路径探测
const candidates = [
  process.argv[3],
  path.join(process.env.USERPROFILE || '.', '.local', 'share', 'opencode'),
  path.join(process.env.APPDATA || '', 'opencode'),
].filter(Boolean);
const statePath = path.join(path.dirname(logPath), 'opencode-state.json');

const USD_TO_CNY = 7.2; // 近似汇率，仅用于展示统一

function pad(n) { return String(n).padStart(2, '0'); }
function fmtTs(ms) {
  const d = new Date(ms);
  if (isNaN(d.getTime())) return null;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
function summary(text, n) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) + '…' : s;
}

function main() {
  let dbFile = null;
  for (const dir of candidates) {
    if (!dir) continue;
    const f = path.join(dir, 'opencode.db');
    if (fs.existsSync(f)) { dbFile = f; break; }
  }
  if (!dbFile) process.exit(0);

  let db;
  try { db = new DatabaseSync(dbFile, { readOnly: true }); } catch { process.exit(0); }

  let lastTs = 0;
  let state = {};
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); lastTs = Number(state.lastTs || 0); } catch { }

  let rows;
  try {
    rows = db.prepare("SELECT id, time, role, modelID, providerID, tokens, cost FROM message WHERE time > ? ORDER BY time ASC").all(lastTs);
  } catch (e) { db.close(); process.exit(0); }
  db.close();
  if (!rows || rows.length === 0) process.exit(0);

  const records = [];
  let maxTs = lastTs;
  const seen = new Set();
  for (const r of rows) {
    if (seen.has(r.id)) continue;
    seen.add(r.id);
    let t = Number(r.time);
    // 时间可能是秒或毫秒
    if (t > 0 && t < 1e12) t *= 1000;
    const ts = fmtTs(t || Date.now());
    if (!ts) continue;
    if (t > maxTs) maxTs = t;
    let tokens = {};
    try { tokens = JSON.parse(r.tokens || '{}'); } catch { }
    const input = Number(tokens.input || 0);
    const output = Number(tokens.output || 0);
    const cache = Number(tokens.cache_read || 0);
    records.push({
      ts,
      model: r.modelID || r.providerID || 'opencode',
      prompt: '',
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: input + output,
      cache_hit: cache,
      cache_miss: Math.max(0, input - cache),
      ratio: input > 0 ? Math.round((cache / input) * 10000) / 10000 : null,
      cost: r.cost != null ? Math.round(Number(r.cost) * USD_TO_CNY * 1e6) / 1e6 : 0,
      elapsed_ms: 0,
      source: 'opencode',
    });
  }

  if (records.length > 0) {
    fs.appendFileSync(logPath, records.map(x => JSON.stringify(x)).join('\n') + '\n', 'utf8');
  }
  try { fs.writeFileSync(statePath, JSON.stringify({ lastTs: maxTs }), 'utf8'); } catch { }
}

main();

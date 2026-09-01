#!/usr/bin/env node
/**
 * cline-monitor.js — 读取 Cline / Roo Code 的任务用量
 * （tasks/<id>/ui_messages.json 中 api_req_started 消息的 tokensIn/cacheReads/cost），
 * 增量追加到日志。
 *
 * 用法: node cline-monitor.js <usage.log 路径>
 * 依赖: Node.js ≥ 18
 */
'use strict';
const fs = require('fs');
const path = require('path');

const logPath = process.argv[2];
if (!logPath) process.exit(1);
const statePath = path.join(path.dirname(logPath), 'cline-state.json');

// 候选任务根（Cline ×2 + Roo + 自定义）
const candidates = [
  process.argv[3],
  path.join(process.env.APPDATA || '', 'Code', 'User', 'globalStorage', 'saoudrizwan.claude-dev', 'tasks'),
  path.join(process.env.USERPROFILE || '', '.cline', 'data', 'tasks'),
  path.join(process.env.APPDATA || '', 'Code', 'User', 'globalStorage', 'rooveterinaryinc.roo-cline', 'tasks'),
].filter(d => d && fs.existsSync(d));

const USD_TO_CNY = 7.2; // 近似汇率

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

function extractFromMessages(messages, lastTs) {
  const records = [];
  let lastUser = '';
  let lastUserTs = 0;
  for (const msg of messages || []) {
    const ts = Number(msg.ts || 0);
    const say = msg.say || msg.ask;
    if (say === 'user' || msg.type === 'ask' && say === 'user') {
      const txt = typeof msg.text === 'string' ? msg.text : '';
      if (txt.trim() && !txt.startsWith('{')) { lastUser = txt; lastUserTs = ts || lastUserTs; }
    }
    if (say !== 'api_req_started' && say !== 'api_req_finished') continue;
    if (ts <= lastTs) continue;
    let info;
    try { info = JSON.parse(msg.text); } catch { continue; }
    if (typeof info.tokensIn !== 'number' && typeof info.tokensOut !== 'number') continue;
    const input = Number(info.tokensIn || 0);
    const output = Number(info.tokensOut || 0);
    const cache = Number(info.cacheReads || 0);
    const t = fmtTs(ts || Date.now());
    if (!t) continue;
    records.push({
      ts: t,
      model: msg.modelInfo?.modelId || 'cline',
      prompt: summary(lastUser, 24),
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: input + output,
      cache_hit: cache,
      cache_miss: Math.max(0, input - cache),
      ratio: input > 0 ? Math.round((cache / input) * 10000) / 10000 : null,
      cost: typeof info.cost === 'number' ? Math.round(info.cost * USD_TO_CNY * 1e6) / 1e6 : 0,
      elapsed_ms: lastUserTs ? Math.max(0, ts - lastUserTs) : 0,
      source: 'cline',
    });
  }
  return records;
}

function main() {
  if (candidates.length === 0) process.exit(0);

  // 状态：{ filePath: lastTs }
  let state = {};
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { }

  const allRecords = [];
  const newState = {};
  for (const root of candidates) {
    let dirs = [];
    try { dirs = fs.readdirSync(root); } catch { continue; }
    for (const id of dirs) {
      if (id.startsWith('.')) continue; // 临时/锁文件
      const f = path.join(root, id, 'ui_messages.json');
      if (!fs.existsSync(f)) continue;
      const lastTs = Number(state[f] || 0);
      let msgs;
      try { msgs = JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, '')); } catch { continue; }
      if (msgs && typeof msgs === 'object' && !Array.isArray(msgs)) msgs = [msgs]; // 兼容单对象
      if (!Array.isArray(msgs)) continue;
      let maxTs = lastTs;
      for (const m of msgs) if (Number(m.ts) > maxTs) maxTs = Number(m.ts);
      newState[f] = maxTs;
      const records = extractFromMessages(msgs, lastTs);
      allRecords.push(...records);
    }
  }

  if (allRecords.length > 0) {
    fs.appendFileSync(logPath, allRecords.map(r => JSON.stringify(r)).join('\n') + '\n', 'utf8');
  }
  try { fs.writeFileSync(statePath, JSON.stringify(newState), 'utf8'); } catch { }
}

main();

#!/usr/bin/env node
/**
 * aider-monitor.js — 读取 aider CLI 会话（~/.aider/history.jsonl），
 * 提取消息 token 用量，增量追加到日志。
 *
 * 用法: node aider-monitor.js <usage.log 路径> [aider 数据目录]
 * 依赖: Node.js ≥ 18
 */
'use strict';
const fs = require('fs');
const path = require('path');

const logPath = process.argv[2];
if (!logPath) process.exit(1);
const aiderRoot = process.argv[3] || path.join(process.env.USERPROFILE || '.', '.aider');
const statePath = path.join(path.dirname(logPath), 'aider-state.json');

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
  const file = path.join(aiderRoot, 'history.jsonl');
  if (!fs.existsSync(file)) process.exit(0);

  let state = { lines: 0 };
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { }

  const all = fs.readFileSync(file, 'utf8');
  const lines = all.split(/\r?\n/);
  const total = lines.length;
  if (total <= (state.lines || 0)) process.exit(0);

  const records = [];
  let lastUser = '';
  let lastUserTs = 0;
  for (let i = (state.lines || 0); i < total; i++) {
    const line = lines[i];
    if (!line.trim()) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    const tsMs = Date.parse(ev.timestamp) || Date.now();
    if (ev.role === 'user') {
      const txt = String(ev.content || '');
      if (txt.trim()) { lastUser = txt; lastUserTs = tsMs; }
    } else if (ev.role === 'assistant') {
      const tc = Number(ev.token_count || 0);
      const ts = fmtTs(tsMs);
      if (!ts) continue;
      records.push({
        ts,
        model: ev.model || 'aider',
        prompt: summary(lastUser, 24),
        prompt_tokens: 0,
        completion_tokens: tc,
        total_tokens: tc,
        cache_hit: 0,
        cache_miss: 0,
        ratio: null,
        cost: ev.cost != null ? Math.round(Number(ev.cost) * 1e6) / 1e6 : 0,
        elapsed_ms: lastUserTs ? Math.max(0, tsMs - lastUserTs) : 0,
        source: 'aider',
      });
    }
  }

  if (records.length > 0) {
    fs.appendFileSync(logPath, records.map(r => JSON.stringify(r)).join('\n') + '\n', 'utf8');
  }
  try { fs.writeFileSync(statePath, JSON.stringify({ lines: total }), 'utf8'); } catch { }
}

main();

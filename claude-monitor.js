#!/usr/bin/env node
/**
 * claude-monitor.js — 读取 Claude Code 会话记录，提取每次请求的真实用量
 * （input_tokens / output_tokens / cache_read_input_tokens），增量追加到日志。
 *
 * 用法: node claude-monitor.js <usage.log 路径> [claude projects 根目录]
 * 依赖: Node.js ≥ 18
 */
'use strict';
const fs = require('fs');
const path = require('path');

const logPath = process.argv[2];
if (!logPath) process.exit(1);
const projectsRoot = process.argv[3] || path.join(process.env.USERPROFILE || '.', '.claude', 'projects');
const statePath = path.join(path.dirname(logPath), 'claude-state.json');

/* ---------------- 工具 ---------------- */
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
  const m = String(model || '');
  if (m.includes('reasoner')) return PRICES['deepseek-reasoner'];
  return PRICES['deepseek-chat'];
}

/* ---------------- 提取记录 ---------------- */
function extractRecords(text) {
  const records = [];
  let lastUser = '';
  let lastUserTime = 0;
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    if (ev.type === 'user') {
      const c = ev.message?.content;
      let txt = '';
      if (typeof c === 'string') txt = c;
      else if (Array.isArray(c)) txt = c.map(b => (typeof b === 'string' ? b : b.text || '')).join(' ');
      if (txt.trim()) { lastUser = txt; lastUserTime = Date.parse(ev.timestamp) || lastUserTime; }
    } else if (ev.message?.type === 'message' && ev.message?.usage) {
      const u = ev.message.usage;
      const input = u.input_tokens || 0;
      const output = u.output_tokens || 0;
      const cache = u.cache_read_input_tokens || 0;
      const model = ev.message.model || 'unknown';
      const p = priceFor(model);
      const cost = (input / 1e6) * p.inputMiss + (cache / 1e6) * p.inputHit + (output / 1e6) * p.output;
      let tsMs = Date.now();
      if (ev.timestamp) { const t = Date.parse(ev.timestamp); if (!isNaN(t)) tsMs = t; }
      else if (ev.message?.ts) { const t = Date.parse(ev.message.ts); if (!isNaN(t)) tsMs = t; }
      records.push({
        ts: fmtTs(tsMs),
        model,
        prompt: summary(lastUser, 24),
        prompt_tokens: input + cache,
        completion_tokens: output,
        total_tokens: input + cache + output,
        cache_hit: cache,
        cache_miss: input,
        ratio: (input + cache) > 0 ? Math.round((cache / (input + cache)) * 10000) / 10000 : null,
        cost: Math.round(cost * 1e6) / 1e6,
        elapsed_ms: lastUserTime ? Math.max(0, tsMs - lastUserTime) : 0,
        source: 'claude',
      });
    }
  }
  return records;
}

/* ---------------- 主流程（全文件增量） ---------------- */
function main() {
  if (!fs.existsSync(projectsRoot)) process.exit(0);

  // 收集所有会话 jsonl
  const files = [];
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir)) {
      const p = path.join(dir, name);
      let st;
      try { st = fs.statSync(p); } catch { continue; }
      if (st.isDirectory()) walk(p);
      else if (name.endsWith('.jsonl')) files.push(p);
    }
  };
  walk(projectsRoot);
  if (files.length === 0) process.exit(0);

  // 状态：{ file 路径 → 已处理行数 }
  let state = {};
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { }

  const allRecords = [];
  const newState = {};
  for (const file of files) {
    let all;
    try { all = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const lines = all.split(/\r?\n/);
    const total = lines.length;
    const from = state[file] || 0;
    newState[file] = total;
    if (total <= from) continue;
    const records = extractRecords(lines.slice(from).join('\n'));
    allRecords.push(...records);
  }

  if (allRecords.length > 0) {
    fs.appendFileSync(logPath, allRecords.map(r => JSON.stringify(r)).join('\n') + '\n', 'utf8');
  }
  try {
    fs.writeFileSync(statePath, JSON.stringify(newState), 'utf8');
  } catch { }
}

main();

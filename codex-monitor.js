#!/usr/bin/env node
/**
 * codex-monitor.js — 读取 Codex CLI 会话用量（state_5.sqlite threads.tokens_used），
 * 按线程 token 增量追加到日志。
 *
 * 用法: node codex-monitor.js <usage.log 路径> [.codex 根目录]
 * 依赖: Node.js ≥ 22.5（node:sqlite，实验特性）
 */
'use strict';
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const path = require('path');

const logPath = process.argv[2];
if (!logPath) process.exit(1);
const codexRoot = process.argv[3] || path.join(process.env.USERPROFILE || '.', '.codex');
const statePath = path.join(path.dirname(logPath), 'codex-state.json');

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
  // 找 state 数据库（state_5.sqlite 或 state_N.sqlite）
  let dbFile = null;
  try {
    for (const name of fs.readdirSync(codexRoot)) {
      if (/^state_\d+\.sqlite$/.test(name)) {
        const f = path.join(codexRoot, name);
        if (!dbFile || fs.statSync(f).mtimeMs > fs.statSync(dbFile).mtimeMs) dbFile = f;
      }
    }
  } catch { }
  if (!dbFile) process.exit(0);

  let db;
  try { db = new DatabaseSync(dbFile, { readOnly: true }); } catch { process.exit(0); }

  let rows;
  try {
    rows = db.prepare("SELECT id, tokens_used, updated_at_ms, model, first_user_message, title FROM threads WHERE tokens_used > 0").all();
  } catch {
    try { rows = db.prepare("SELECT id, tokens_used, updated_at_ms, model, first_user_message, title FROM threads").all(); }
    catch { db.close(); process.exit(0); }
  }
  db.close();
  if (!rows || rows.length === 0) process.exit(0);

  let state = {};
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { }

  const records = [];
  for (const r of rows) {
    const id = r.id;
    const used = Number(r.tokens_used || 0);
    const prev = Number(state[id] || 0);
    if (used <= prev) continue;
    const delta = used - prev;
    const ts = fmtTs(Number(r.updated_at_ms) || Date.now());
    if (!ts) continue;
    records.push({
      ts,
      model: r.model || 'codex',
      prompt: summary(r.first_user_message || r.title || '', 24),
      prompt_tokens: 0,
      completion_tokens: delta,
      total_tokens: delta,
      cache_hit: 0,
      cache_miss: 0,
      ratio: null,
      cost: 0,
      elapsed_ms: 0,
      source: 'codex',
    });
    state[id] = used;
  }

  if (records.length > 0) {
    fs.appendFileSync(logPath, records.map(x => JSON.stringify(x)).join('\n') + '\n', 'utf8');
  }
  try { fs.writeFileSync(statePath, JSON.stringify(state), 'utf8'); } catch { }
}

main();

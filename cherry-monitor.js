#!/usr/bin/env node
/**
 * cherry-monitor.js — 读取 Cherry Studio 用量记录（cherrystudio.sqlite ai_usage_record 表），
 * 增量追加到日志。
 *
 * 用法: node cherry-monitor.js <usage.log 路径> [CherryStudio 数据目录]
 * 依赖: Node.js ≥ 22.5（node:sqlite）
 */
'use strict';
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const path = require('path');

const logPath = process.argv[2];
if (!logPath) process.exit(1);
const dataDir = process.argv[3] || path.join(process.env.APPDATA || '', 'CherryStudio', 'Data');
const statePath = path.join(path.dirname(logPath), 'cherry-state.json');

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
  const dbFile = path.join(dataDir, 'cherrystudio.sqlite');
  if (!fs.existsSync(dbFile)) process.exit(0);

  let db;
  try { db = new DatabaseSync(dbFile, { readOnly: true }); } catch { process.exit(0); }

  let lastTs = 0;
  let state = {};
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); lastTs = Number(state.lastTs || 0); } catch { }

  let rows;
  try {
    rows = db.prepare(
      "SELECT id, model_name, input_tokens, output_tokens, total_tokens, reasoning_tokens, no_cache_tokens, cache_read_tokens, cache_write_tokens, cost, created_at, message_id FROM ai_usage_record WHERE modality = 'language' AND created_at > ? ORDER BY created_at ASC"
    ).all(lastTs);
  } catch (e) { db.close(); process.exit(0); }
  db.close();

  if (!rows || rows.length === 0) process.exit(0);

  const records = [];
  let maxTs = lastTs;
  const seen = new Set();
  for (const r of rows) {
    const ts = fmtTs(Number(r.created_at));
    if (!ts) continue;
    if (seen.has(r.id)) continue;
    seen.add(r.id);
    if (Number(r.created_at) > maxTs) maxTs = Number(r.created_at);
    const input = Number(r.input_tokens || 0);
    const output = Number(r.output_tokens || 0);
    const cache = Number(r.cache_read_tokens || 0);
    const miss = r.no_cache_tokens != null ? Number(r.no_cache_tokens) : Math.max(0, input - cache);
    records.push({
      ts,
      model: r.model_name || 'cherry',
      prompt: '',
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: Number(r.total_tokens || 0) || input + output,
      cache_hit: cache,
      cache_miss: miss,
      ratio: input > 0 ? Math.round((cache / input) * 10000) / 10000 : null,
      cost: r.cost != null ? Math.round(Number(r.cost) * 1e6) / 1e6 : 0,
      elapsed_ms: 0,
      source: 'cherry',
    });
  }

  if (records.length > 0) {
    fs.appendFileSync(logPath, records.map(x => JSON.stringify(x)).join('\n') + '\n', 'utf8');
  }
  try { fs.writeFileSync(statePath, JSON.stringify({ lastTs: maxTs }), 'utf8'); } catch { }
}

main();

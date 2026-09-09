#!/usr/bin/env node
/**
 * 按 docx/tools/doc-numbers.json 归一化每篇文档头部的『文档编号』，
 * 并对缺少元信息块的自动生成物插入标准头。
 * 用法（项目根目录）：node docx/tools/normalize-doc-numbers.js
 * 幂等：重复执行输出 CHANGED=0。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const map = JSON.parse(fs.readFileSync(path.join(__dirname, 'doc-numbers.json'), 'utf8'));

function walk(dir, acc) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'tools') walk(p, acc); }
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}

const changed = [];
const unknown = [];
for (const f of walk(ROOT, [])) {
  const rel = path.relative(ROOT, f).split(path.sep).join('/');
  const want = map[rel];
  if (!want) { unknown.push(rel); continue; }
  let txt = fs.readFileSync(f, 'utf8');
  const re = /^> 文档编号：.*$/m;
  if (re.test(txt)) {
    const before = txt.match(re)[0];
    const next = '> 文档编号：' + want;
    if (before !== next) { txt = txt.replace(re, next); changed.push(rel + ': ' + before.replace('> 文档编号：', '') + ' -> ' + want); }
  } else {
    const h1 = txt.match(/^# .*$/m);
    if (h1) {
      txt = txt.replace(h1[0], h1[0] + '\n\n> 文档编号：' + want + '\n> 级别：L1 📌\n> 状态：现行\n> 关联代码：项目根目录 api.json（脚本自动生成）\n> 最近更新：2026-09-08\n> 变更触发条件：api.json 更新后重新生成\n');
      changed.push(rel + ': (插入元信息块) -> ' + want);
    }
  }
  fs.writeFileSync(f, txt, 'utf8');
}
console.log('CHANGED=' + changed.length);
for (const c of changed) console.log('  ' + c);
console.log('UNKNOWN=' + unknown.length + (unknown.length ? ' ' + unknown.join(', ') : ''));
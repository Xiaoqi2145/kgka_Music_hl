#!/usr/bin/env node
/**
 * KA Music 知识库健康度检查器（对应 WBS T-M7-05）
 * 用法：node docx/tools/check-docs.js
 * 退出码：0 = 全部通过；1 = 存在失败项
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

function walk(dir, acc) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'tools') walk(p, acc); }
    else if (e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}

const files = walk(ROOT, []).sort();
const problems = [];
const rel = (p) => path.relative(ROOT, p).split(path.sep).join('/');

// 1) 元信息块
const META = ['文档编号：', '级别：', '状态：', '关联代码：', '最近更新：', '变更触发条件：'];
// 2) 必备章节（索引/生成物除外）
const SECTIONS = ['TL;DR', '约束与坑', '待办'];
const EXEMPT_SECTIONS = ['README.md', '00-元数据/术语表.md', '04-数据与接口/API-端点清单.md', '04-数据与接口/API-Schema索引.md'];

const numbers = new Map();
const linkRe = /\[[^\]]*\]\(([^)#]+)(#[^)]*)?\)/g;

for (const f of files) {
  const r = rel(f);
  const txt = fs.readFileSync(f, 'utf8');

  for (const m of META) if (!txt.includes(m)) problems.push('META  ' + r + ' 缺少「' + m + '」');
  if (!EXEMPT_SECTIONS.includes(r)) {
    for (const s of SECTIONS) if (!txt.includes(s)) problems.push('SECT ' + r + ' 缺少章节「' + s + '」');
  }

  const num = (txt.match(/^> 文档编号：(.+)$/m) || [])[1];
  if (num) {
    const key = num.trim();
    if (numbers.has(key)) problems.push('DUP  ' + r + ' 编号 ' + key + ' 与 ' + numbers.get(key) + ' 重复');
    else numbers.set(key, r);
  }

  const scannable = txt
    .replace(/```[\s\S]*?```/g, '')
    .replace(/`[^`]*`/g, '');
  let m;
  while ((m = linkRe.exec(scannable))) {
    const target = m[1].trim();
    if (/^(https?:|mailto:)/.test(target)) continue;
    const resolved = path.resolve(path.dirname(f), decodeURIComponent(target));
    if (!fs.existsSync(resolved)) { problems.push('LINK ' + r + ' -> ' + target + ' 不存在'); continue; }
    if (fs.statSync(resolved).isDirectory()) {
      const inner = fs.readdirSync(resolved).filter((x) => x.endsWith('.md'));
      if (inner.length === 0) problems.push('DIR  ' + r + ' -> ' + target + ' 目录为空');
    }
  }
}

// 3) 索引一致性：README 是否登记了全部文档
const readme = fs.readFileSync(path.join(ROOT, 'README.md'), 'utf8');
for (const f of files) {
  const r = rel(f);
  if (r === 'README.md') continue;
  const base = path.basename(r);
  if (!readme.includes(base)) problems.push('IDX  ' + r + ' 未在 README 索引中登记');
}

console.log('检查文档数：' + files.length);
console.log('唯一编号数：' + numbers.size);
if (problems.length === 0) {
  console.log('✅ 全部通过：无死链、无编号冲突、元信息与章节齐备、索引完整。');
  process.exit(0);
}
console.log('❌ 发现 ' + problems.length + ' 个问题：');
for (const p of problems) console.log('  - ' + p);
process.exit(1);
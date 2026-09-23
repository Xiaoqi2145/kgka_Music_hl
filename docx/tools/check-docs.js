#!/usr/bin/env node
/**
 * KA Music 知识库健康度检查器（对应 WBS T-M7-05）
 * 用法：node docx/tools/check-docs.js
 *       node docx/tools/check-docs.js --anchors-blocking   # 锚点漂移也计入退出码
 * 退出码：0 = 全部通过；1 = 存在失败项
 *
 * 检查项：
 *   1) 元信息块 / 必备章节 / 文档编号唯一性
 *   2) 相对链接可达性
 *   3) README 索引完整性
 *   4) 行号锚点漂移（信息段，见 §4 说明）
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

  // 剥离代码块与行内代码后再做元信息/章节/编号检查。
  // 两个坑：
  //   1) 文档模板示例（如「00-元数据/文档规范与维护约定.md」§4 的模板块）会让头部字段
  //      缺失的文档蒙混过关 —— 该文档曾因此长期未被发现缺 4 个头部字段。
  //   2) 行内代码匹配必须禁止跨行（[^`\n]*）。若写成 [^`]*，文档中一个未配对的反引号
  //      就会把后续整段正文吞掉，导致「约束与坑」「待办」章节被误判为缺失。
  const prose = txt.replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, '');

  for (const m of META) if (!prose.includes(m)) problems.push('META  ' + r + ' 缺少「' + m + '」');
  if (!EXEMPT_SECTIONS.includes(r)) {
    for (const s of SECTIONS) if (!prose.includes(s)) problems.push('SECT ' + r + ' 缺少章节「' + s + '」');
  }

  const num = (prose.match(/^> 文档编号：(.+)$/m) || [])[1];
  if (num) {
    const key = num.trim();
    if (numbers.has(key)) problems.push('DUP  ' + r + ' 编号 ' + key + ' 与 ' + numbers.get(key) + ' 重复');
    else numbers.set(key, r);
  }

  const scannable = prose;
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

/* ------------------------------------------------------------------
 * 4) 行号锚点漂移
 *
 * 背景：docx/ 有近 3000 处 `文件:行号` 锚点。行号在写入时准确，之后任何一次
 * 在锚点之前插入/删除代码行都会让它指向别处，且不报错。本检查补上这个闭环。
 *
 * 判据（只查「显式锚点」——锚点自带完整文件名，无上下文歧义）：
 *   锚点所指行内容为「空行」或「仅由 } ) ; ] , 组成」→ 判为漂移。
 * 该判据不产生假阳性：一个有意指向右括号的锚点，本身也是无效锚点。
 *
 * 不覆盖：`:NNN` 简写锚点。其文件归属依赖表格列头/行主语/章节标题等上下文，
 * 机器推断不可靠（误判率实测很高），故只作「需人工复核」处理，不在此判定。
 * 要扩大覆盖，应先在文档里把简写锚点补成完整文件名。
 *
 * 结果作为独立信息段输出，默认不影响退出码（当前存量较大，设为阻断会让门禁
 * 长期红）。清到 0 后可用 --anchors-blocking 提升为阻断项。
 * ------------------------------------------------------------------ */
const ANCHOR_EXTS = ['dart', 'kt', 'xml', 'yaml', 'yml', 'gradle', 'kts', 'json', 'md', 'lock', 'properties'];
const ANCHOR_RE = new RegExp(
  '([A-Za-z0-9_\\-./]+\\.(?:' + ANCHOR_EXTS.join('|') + ')):(\\d+)', 'g');

// 注意：本文件的 ROOT 指向 docx/（文档树的根），而锚点指向的是仓库根下的源码。
// 建代码索引必须从 REPO 出发，否则会把锚点解析到 docx/ 内部。
const REPO = path.resolve(__dirname, '..', '..');
const relRepo = (p) => path.relative(REPO, p).split(path.sep).join('/');

const SKIP_DIRS = new Set(['.git', 'build', '.dart_tool', 'node_modules', '.idea',
  'coverage', 'Pods', 'ephemeral', 'debug', 'profile', 'release', 'docx']);

const codeIndex = new Map();   // basename / 仓库相对路径 -> 仓库相对路径
(function buildCodeIndex(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) buildCodeIndex(p); }
    else if (ANCHOR_EXTS.some((x) => e.name.endsWith('.' + x))) {
      const r = relRepo(p);
      codeIndex.set(e.name, codeIndex.get(e.name) || r);
      codeIndex.set(r, r);
    }
  }
})(REPO);

const lineCache = new Map();
function getLines(r) {
  if (!lineCache.has(r)) {
    const p = path.join(REPO, r);
    lineCache.set(r, fs.existsSync(p) ? fs.readFileSync(p, 'utf8').split('\n') : null);
  }
  return lineCache.get(r);
}

// 空行、纯括号/分号行、或只有注释标记的行 → 视为无效行
// 注意字符类里 `]` 必须转义，否则它会提前闭合字符类（曾因此漏报大半漂移）。
function isTrivial(s) {
  const t = s.trim();
  if (!t) return true;
  if (/^[)\]};,]+$/.test(t)) return true;
  if (t.startsWith('//') && t.length <= 12) return true;
  return false;
}

const anchorHits = [];      // { doc, line, anchor, got }
let anchorTotal = 0;

for (const f of files) {
  const r = rel(f);
  const lines = fs.readFileSync(f, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    let m;
    ANCHOR_RE.lastIndex = 0;
    while ((m = ANCHOR_RE.exec(lines[i]))) {
      const target = m[1];
      const lineNo = parseInt(m[2], 10);
      const resolved = codeIndex.get(target) || codeIndex.get(target.replace(/^.*\//, ''));
      if (!resolved) continue;              // 不是仓库内文件（SDK/依赖包）→ 跳过
      const src = getLines(resolved);
      if (!src) continue;
      anchorTotal++;
      if (lineNo < 1 || lineNo > src.length || isTrivial(src[lineNo - 1])) {
        anchorHits.push({
          doc: r, line: i + 1, anchor: target + ':' + lineNo,
          got: lineNo > src.length ? '<越界，共 ' + src.length + ' 行>' : src[lineNo - 1].trim().slice(0, 40),
        });
      }
    }
  }
}

/* ------------------------------------------------------------------ */

console.log('检查文档数：' + files.length);
console.log('唯一编号数：' + numbers.size);
console.log('显式行号锚点：' + anchorTotal + '，其中漂移 ' + anchorHits.length +
  '（' + (anchorTotal ? (anchorHits.length * 100 / anchorTotal).toFixed(1) : '0.0') + '%）');

const anchorsBlocking = process.argv.includes('--anchors-blocking');
const blocking = problems.length + (anchorsBlocking ? anchorHits.length : 0);

if (anchorHits.length) {
  const byDoc = new Map();
  for (const h of anchorHits) byDoc.set(h.doc, (byDoc.get(h.doc) || 0) + 1);
  const top = [...byDoc.entries()].sort((a, b) => b[1] - a[1]);
  console.log('');
  console.log('⚠️  行号锚点漂移 ' + anchorHits.length + ' 处，分布在 ' + byDoc.size + ' 篇文档' +
    (anchorsBlocking ? '（已计入退出码）' : '（信息项，不影响退出码）'));
  if (process.argv.includes('--anchors-list')) {
    // 全量清单：按文档分组，供逐条修复使用
    for (const [d, n] of top) {
      console.log('');
      console.log('  ' + d + '（' + n + '）');
      for (const h of anchorHits.filter((x) => x.doc === d)) {
        console.log('     L' + h.line + '  ' + h.anchor + "  →  '" + h.got + "'");
      }
    }
  } else {
    for (const [d, n] of top.slice(0, 10)) console.log('     ' + String(n).padStart(3) + '  ' + d);
    if (top.length > 10) console.log('     ...  其余 ' + (top.length - 10) + ' 篇');
    console.log('     前 5 条明细：');
    for (const h of anchorHits.slice(0, 5)) {
      console.log('       ' + h.doc + ':' + h.line + '  ' + h.anchor + "  →  '" + h.got + "'");
    }
  }
  console.log('     说明：判据为「锚点指向空行或纯括号行」。仅覆盖显式锚点；');
  console.log('           `:NNN` 简写锚点依赖上下文，需人工复核。');
  console.log('           全量清单：node docx/tools/check-docs.js --anchors-list');
}

if (blocking === 0) {
  console.log('✅ 全部通过：无死链、无编号冲突、元信息与章节齐备、索引完整。');
  process.exit(0);
}
if (problems.length) {
  console.log('❌ 发现 ' + problems.length + ' 个问题：');
  for (const p of problems) console.log('  - ' + p);
}
if (anchorsBlocking && anchorHits.length) {
  console.log('❌ 锚点漂移 ' + anchorHits.length + ' 处（--anchors-blocking）');
}
process.exit(1);

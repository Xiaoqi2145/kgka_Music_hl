#!/usr/bin/env node
/**
 * 从项目根目录 api.json 重新生成：
 *   docx/04-数据与接口/API-端点清单.md
 *   docx/04-数据与接口/API-Schema索引.md
 * 用法（项目根目录）：node docx/tools/gen-api-docs.js
 * 对应 WBS T-M0-07。禁止手工编辑这两份生成物。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..', '..');
const OUT = path.resolve(__dirname, '..', '04-数据与接口');
const spec = JSON.parse(fs.readFileSync(path.join(ROOT, 'api.json'), 'utf8'));
const BT = String.fromCharCode(96);

const rows = [];
for (const [p, ops] of Object.entries(spec.paths)) {
  for (const [m, op] of Object.entries(ops)) {
    const params = (op.parameters || []).map((x) => BT + x.name + (x.required ? '*' : '') + BT).join(', ');
    rows.push({ m: m.toUpperCase(), p, tags: (op.tags || []).join('/'), summary: (op.summary || '').replace(/\s+/g, ' '), params });
  }
}
const byTag = {};
for (const r of rows) (byTag[r.tags] = byTag[r.tags] || []).push(r);

let md = '# KA Music 后端 API 端点清单（自动生成）\n\n';
md += '> 文档编号：KA-04-03\n> 级别：L1 📌\n> 状态：现行\n> 关联代码：项目根目录 api.json（脚本自动生成）\n> 最近更新：2026-09-08\n> 变更触发条件：api.json 更新后重新生成\n\n';
md += '> 来源：' + BT + 'api.json' + BT + '（OpenAPI 3.1.1，title = ' + spec.info.title + '，servers = ' + (spec.servers || []).map((s) => s.url).join(', ') + '）。\n';
md += '> 生成命令：' + BT + 'node docx/tools/gen-api-docs.js' + BT + '。参数列中 ' + BT + '*' + BT + ' 表示 required=true。\n\n';
md += '## 统计\n\n- 端点（method x path）：**' + rows.length + '**\n- 路径数：**' + Object.keys(spec.paths).length + '**\n- 标签分组数：**' + Object.keys(byTag).length + '**\n\n';
md += '## 按标签分组的端点\n\n';
for (const tag of Object.keys(byTag).sort()) {
  md += '### ' + tag + '（' + byTag[tag].length + '）\n\n| Method | Path | 说明 | 参数 |\n|---|---|---|---|\n';
  for (const r of byTag[tag].sort((a, b) => a.p.localeCompare(b.p))) md += '| ' + r.m + ' | ' + BT + r.p + BT + ' | ' + (r.summary || '-') + ' | ' + (r.params || '-') + ' |\n';
  md += '\n';
}
md += '## 端点全量索引（按路径排序）\n\n| Path | Method | Tag | 说明 |\n|---|---|---|---|\n';
for (const r of rows.slice().sort((a, b) => a.p.localeCompare(b.p) || a.m.localeCompare(b.m))) md += '| ' + BT + r.p + BT + ' | ' + r.m + ' | ' + r.tags + ' | ' + (r.summary || '-') + ' |\n';
fs.writeFileSync(path.join(OUT, 'API-端点清单.md'), md);

const schemas = Object.entries((spec.components || {}).schemas || {});
let sm = '# KA Music 后端 API Schema 索引（自动生成）\n\n';
sm += '> 文档编号：KA-04-04\n> 级别：L1 📌\n> 状态：现行\n> 关联代码：项目根目录 api.json（脚本自动生成）\n> 最近更新：2026-09-08\n> 变更触发条件：api.json 更新后重新生成\n\n';
sm += '> 共 **' + schemas.length + '** 个 schema，来源 ' + BT + 'components.schemas' + BT + '。\n\n| # | Schema | 类型 | 属性数 | 属性名 |\n|---|---|---|---|---|\n';
schemas.forEach(([name, def], i) => {
  const props = def.properties ? Object.keys(def.properties) : [];
  sm += '| ' + (i + 1) + ' | ' + BT + name + BT + ' | ' + (def.type || (def.properties ? 'object' : '-')) + ' | ' + props.length + ' | ' + props.slice(0, 25).map((x) => BT + x + BT).join(', ') + (props.length > 25 ? ' …' : '') + ' |\n';
});
fs.writeFileSync(path.join(OUT, 'API-Schema索引.md'), sm);
console.log('已生成：端点 ' + rows.length + ' 个、schema ' + schemas.length + ' 个');
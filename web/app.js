/* 小学数学辅导 · 本地版 —— 前端交互
 *
 * 刻意做"薄"：所有出题、判分、复习调度都在服务端 Dart 内核里做。
 * 浏览器拿到的题目**不含答案**（防偷看），只负责显示与收集作答。
 */

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

let currentPaper = null;   // {paperId, items:[...]}
const answers = new Map(); // id -> 用户答案

// ── 工具 ────────────────────────────────────────────
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => t.classList.add('hidden'), 2200);
}

async function api(path, opts) {
  const res = await fetch(path, opts);
  if (!res.ok) {
    const txt = await res.text();
    let msg = txt;
    try { msg = JSON.parse(txt).error || txt; } catch (_) {}
    throw new Error(msg);
  }
  const ct = res.headers.get('content-type') || '';
  return ct.includes('json') ? res.json() : res;
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"]/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function dueLabel(ms) {
  const d = new Date(ms);
  const now = new Date();
  const diff = (d - now) / 86400000;
  if (diff <= 0) return '今天该复习';
  if (diff < 1) return '几小时后';
  return `${Math.round(diff)} 天后复习`;
}

// ── 视图切换 ────────────────────────────────────────
// 抽成函数是为了支持 #book / #review / #look 深链接 ——
// 手机上「添加到主屏幕」后，图标可以直接指向某一页。
function showView(v) {
  const btn = $(`#tabs .tab[data-view="${v}"]`);
  if (!btn) return;
  $$('#tabs .tab').forEach((b) => b.classList.remove('active'));
  btn.classList.add('active');
  $$('.view').forEach((s) => s.classList.toggle('active', s.id === `view-${v}`));
  if (v === 'book') loadBook();
  if (v === 'review') loadDue();
  if (v === 'look') loadSamples();
}

$$('#tabs .tab').forEach((btn) => {
  btn.addEventListener('click', () => {
    const v = btn.dataset.view;
    // 用 replaceState 不往历史里堆，否则「返回」要按很多次
    if (location.hash !== `#${v}`) history.replaceState(null, '', `#${v}`);
    showView(v);
  });
});

window.addEventListener('hashchange', () => showView(location.hash.slice(1)));

// ── 观感验收：同一组样例，安卓和苹果看的是一套东西 ────
async function loadSamples() {
  const geo = document.getElementById('geoArea');
  const vert = document.getElementById('vertArea');
  if (!geo) return;
  geo.textContent = '加载中…'; vert.textContent = '加载中…';
  try {
    const data = await api('/api/samples');
    const card = (q, i) => `
      <div class="qcard">
        <div class="qhead"><span class="qno">${i + 1}.</span><span class="qtag">${esc(q.kpPath)}</span></div>
        <div class="qstem">${esc(q.stem)}</div>
        ${q.figureSvg ? `<div class="figure">${q.figureSvg}</div>` : ''}
        ${q.verticalSvg ? `<div class="vert">${q.verticalSvg}</div>` : ''}
      </div>`;
    geo.innerHTML = data.geometry.length
      ? data.geometry.map(card).join('')
      : '<p class="hint">这一轮没抽到几何题，点「换一组样例」再试。</p>';
    vert.innerHTML = data.vertical.length
      ? data.vertical.map(card).join('')
      : '<p class="hint">这一轮没抽到竖式题，点「换一组样例」再试。</p>';
  } catch (e) {
    geo.textContent = '样例加载失败：' + e.message;
    vert.textContent = '';
  }
}

// ── 年级与知识点 ────────────────────────────────────
const gradeSel = $('#gradeSel');
for (let g = 1; g <= 6; g++) {
  const o = document.createElement('option');
  o.value = g; o.textContent = `${g} 年级`;
  if (g === 3) o.selected = true;
  gradeSel.appendChild(o);
}

async function loadTopics() {
  const g = gradeSel.value;
  $('#topicSel').innerHTML = '<option value="">（不限，随机练）</option>';
  try {
    const data = await api(`/api/topics?grade=${g}`);
    for (const u of data.units) {
      const og = document.createElement('optgroup');
      og.label = `${u.domain} · ${u.name}`;
      for (const p of u.points) {
        const o = document.createElement('option');
        o.dataset.unit = u.name;
        o.value = p.name;
        o.textContent = `${u.name} → ${p.name}`;
        og.appendChild(o);
      }
      if (og.children.length) $('#topicSel').appendChild(og);
    }
  } catch (e) { toast('知识点加载失败：' + e.message); }
}

// ── 出卷 ────────────────────────────────────────────
$('#newPaperBtn').addEventListener('click', newPaper);

async function newPaper() {
  const btn = $('#newPaperBtn');
  const level = Number($('#levelSel').value) || 1;
  btn.disabled = true;
  btn.textContent = level > 1 ? 'AI 出题中…' : '出题中…';
  try {
    const sel = $('#topicSel');
    const opt = sel.options[sel.selectedIndex];
    const data = await api('/api/practice', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        grade: Number(gradeSel.value),
        unit: opt ? opt.dataset.unit || '' : '',
        tag: sel.value || '',
        count: Math.max(1, Math.min(20, Number($('#countInput').value) || 5)),
        level,
      }),
    });
    currentPaper = data;
    answers.clear();
    renderPaper(data.items);
    const note = $('#aiNote');
    if (data.note) { note.textContent = '✨ ' + data.note; note.classList.remove('hidden'); }
    else note.classList.add('hidden');
    $('#resultArea').classList.add('hidden');
    window.scrollTo({ top: 0, behavior: 'smooth' });
  } catch (e) {
    toast(e.message);
  } finally {
    btn.disabled = false; btn.textContent = '出一套题';
  }
}

function renderPaper(items) {
  const area = $('#paperArea');
  area.innerHTML = items.map((q, i) => `
    <div class="qcard" data-id="${esc(q.id)}">
      <div class="qhead">
        <span class="qno">${i + 1}.</span>
        <span class="qtag">${esc(q.kpPath)}</span>
        ${q.source === 'ai' ? '<span class="qai">AI 新题</span>' : ''}
      </div>
      <div class="qstem">${esc(q.stem)}</div>
      ${q.figureSvg ? `<div class="figure">${q.figureSvg}</div>` : ''}
      ${q.verticalSvg ? `<div class="vert">${q.verticalSvg}</div>` : ''}
      <div class="answer-row">
        <input type="text" placeholder="写答案" autocomplete="off">
        <span class="verdict"></span>
      </div>
      <div class="steps hidden"></div>
    </div>`).join('');
  area.classList.remove('hidden');

  area.querySelectorAll('.qcard').forEach((card) => {
    const input = card.querySelector('input');
    input.addEventListener('input', () => answers.set(card.dataset.id, input.value));
    input.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      const next = card.nextElementSibling?.querySelector('input');
      if (next) next.focus(); else submitPaper();
    });
  });
  const first = area.querySelector('input');
  if (first) first.focus();

  const foot = document.createElement('div');
  foot.className = 'panel';
  foot.innerHTML = `<div class="row">
      <button class="primary" id="submitBtn">提交批改</button>
      <span class="hint">有余数的题可以直接写「9……2」，也能写成「9余2」</span>
    </div>`;
  area.appendChild(foot);
  foot.querySelector('#submitBtn').addEventListener('click', submitPaper);
}

// ── 提交批改 ────────────────────────────────────────
async function submitPaper() {
  if (!currentPaper) return;
  const btn = $('#submitBtn');
  if (btn) { btn.disabled = true; btn.textContent = '批改中…'; }
  try {
    const payload = currentPaper.items.map((q) => ({
      id: q.id, answer: answers.get(q.id) || '',
    }));
    const data = await api('/api/check', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ paperId: currentPaper.paperId, answers: payload }),
    });

    for (const r of data.results) {
      const card = $(`.qcard[data-id="${CSS.escape(r.id)}"]`);
      if (!card) continue;
      card.classList.add(r.correct ? 'correct' : 'wrong');
      const v = card.querySelector('.verdict');
      v.className = 'verdict ' + (r.correct ? 'ok' : 'bad');
      v.textContent = r.correct
        ? '✓ 对了'
        : `✗ 正确答案是 ${r.expected}${r.expectedUnit ? ' ' + r.expectedUnit : ''}`;
      const stepsBox = card.querySelector('.steps');
      if (r.steps && r.steps.length) {
        stepsBox.innerHTML = '<ol>' + r.steps.map((s) => `<li>${esc(s)}</li>`).join('') + '</ol>';
        stepsBox.classList.remove('hidden');
      }
      const input = card.querySelector('input');
      if (input) input.disabled = true;
    }

    const s = data.summary;
    $('#resultArea').innerHTML = `
      <div class="big">${s.correct} / ${s.total} 做对了</div>
      <div class="line">${s.wrong === 0
        ? '全对！错的家常清单没有新增。'
        : `有 ${s.wrong} 道进了错题本：${s.due} 条到期要复习，${s.attention} 条需要重点关照。`}</div>`;
    $('#resultArea').classList.remove('hidden');
    refreshBadges();
    $('#resultArea').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  } catch (e) {
    toast(e.message);
  }
}

// ── 错题本 ──────────────────────────────────────────
async function loadBook() {
  try {
    const data = await api('/api/book');
    const st = data.stats;
    $('#bookStats').innerHTML = `
      <div><b>${data.records.length}</b> 条记录</div>
      <div><b>${st.due}</b> 条到期</div>
      <div><b>${st.attention}</b> 条要重点看</div>`;
    const list = $('#bookList');
    if (!data.records.length) {
      list.innerHTML = '<div class="empty">还没有错题。先去「练习」做几道题。</div>';
      return;
    }
    list.innerHTML = data.records.map((r) => `
      <div class="item">
        <div class="item-top">
          <div>
            <div class="item-stem">${esc(r.stem)}</div>
            <div class="item-meta">${esc(r.kpPath)} · 答对 ${r.rightCount} 次 / 答错 ${r.wrongCount} 次 · ${dueLabel(r.due)}</div>
          </div>
          <span class="imp ${r.importance === 0 ? 'zero' : ''}">重要度 ${r.importance}</span>
        </div>
        <div class="item-answer">答案：<b>${esc(r.answer)}</b></div>
      </div>`).join('');
  } catch (e) { toast(e.message); }
}

// ── 复习队列 ────────────────────────────────────────
async function loadDue() {
  try {
    const data = await api('/api/review');
    $('#reviewSub').textContent = data.count
      ? `${data.count} 条到期了 —— 间隔按 FSRS 排：答对了会往后推，答错马上回到队首。`
      : '暂时没有到期的题目。';
    const list = $('#dueList');
    if (!data.records.length) {
      list.innerHTML = '<div class="empty">今天没有要复习的，去玩吧 🎈</div>';
      return;
    }
    list.innerHTML = data.records.map((r) => `
      <div class="item due">
        <div class="item-top">
          <div>
            <div class="item-stem">${esc(r.stem)}</div>
            <div class="item-meta">${esc(r.kpPath)} · 连续答对 ${r.streak} 次</div>
          </div>
          <span class="imp ${r.importance === 0 ? 'zero' : ''}">重要度 ${r.importance}</span>
        </div>
        <div class="item-answer">答案：<b>${esc(r.answer)}</b></div>
      </div>`).join('');
  } catch (e) { toast(e.message); }
}

// ── 导出 PDF ────────────────────────────────────────
async function downloadPdf(url, body, fallbackName) {
  try {
    const res = await api(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    const blob = await res.blob();
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = fallbackName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 3000);
    toast('已生成 PDF');
  } catch (e) { toast(e.message || '导出失败'); }
}

$('#exportQuizBtn').addEventListener('click', () =>
  downloadPdf('/api/export', { mode: 'quiz', source: 'book', title: '错题练习卷' }, '错题练习卷.pdf'));
$('#exportAnsBtn').addEventListener('click', () =>
  downloadPdf('/api/export', { mode: 'answer', source: 'book', title: '错题练习卷' }, '错题练习卷-答案.pdf'));
$('#exportDueBtn').addEventListener('click', () =>
  downloadPdf('/api/export', { mode: 'quiz', source: 'due', title: '今日复习卷' }, '今日复习卷.pdf'));

$('#clearBookBtn').addEventListener('click', async () => {
  if (!confirm('确定清空全部错题记录？这一步不可恢复。')) return;
  try {
    await fetch('/api/book', { method: 'DELETE' });
    toast('已清空');
    loadBook();
    refreshBadges();
  } catch (e) { toast(e.message); }
});

// ── 角标 ────────────────────────────────────────────
async function refreshBadges() {
  try {
    const s = await api('/api/stats');
    $('#bookBadge').textContent = s.total;
    $('#dueBadge').textContent = s.due;
  } catch (_) {}
}

// ── 启动 ────────────────────────────────────────────
// 样例卷：直接在手机上打开 PDF（Safari 能预览并打印，安卓会走下载/预览）
const _samplePdfBtn = document.getElementById('samplePdfBtn');
if (_samplePdfBtn) {
  _samplePdfBtn.addEventListener('click', () => {
    // 用 GET 打开而不是 blob 下载：iOS Safari 对 blob 下载支持不稳，
    // 直接跳地址能在页面内预览，右上角就能打印
    window.open('/api/sample-pdf', '_blank');
  });
}
const _reloadSamplesBtn = document.getElementById('reloadSamplesBtn');
if (_reloadSamplesBtn) _reloadSamplesBtn.addEventListener('click', loadSamples);

gradeSel.addEventListener('change', loadTopics);
loadTopics();
refreshBadges();

// 带 #book / #review / #look 直接打开时，落到对应页
if (location.hash.length > 1) showView(location.hash.slice(1));

// 浏览器端到端验收：出题 → 作答 → 批改 → 错题本 → 复习（一次跑完 + 截图）
const path = require('path');
const pw = require('C:/Users/Lenovo/AppData/Roaming/npm/node_modules/@playwright/cli/node_modules/playwright-core');

(async () => {
  const b = await pw.chromium.launch({ channel: 'msedge' });
  const page = await b.newPage({ viewport: { width: 1000, height: 900 } });
  const shots = path.resolve('build');

  await page.goto('http://127.0.0.1:8787');
  // 等知识点树异步加载完（option 会变多）
  await page.waitForFunction(() => document.querySelectorAll('#gradeSel option').length >= 6);

  // ── 1) 出一套五年级的题 ──
  await page.selectOption('#gradeSel', '5');
  await page.click('#newPaperBtn');
  await page.waitForSelector('.qcard');
  const n = (await page.$$('.qcard')).length;
  console.log(`出题: ${n} 道`);
  await page.screenshot({ path: `${shots}/ui_paper.png`, fullPage: true });

  // ── 2) 作答：前两道故意错，其余留空 ──
  const inputs = await page.$$('.qcard input[type=text]');
  await inputs[0].fill('999');
  if (inputs[1]) await inputs[1].fill('随便写写');
  await page.click('#submitBtn');
  await page.waitForSelector('.result:not(.hidden)');
  const verdicts = await page.$$eval('.verdict', (els) => els.map((e) => e.textContent));
  console.log('批改:', verdicts.join(' | '));
  console.log('结果栏:', await page.$eval('.result .line', (e) => e.textContent));
  await page.screenshot({ path: `${shots}/ui_graded.png`, fullPage: true });

  // ── 3) 错题本 ──
  await page.click('[data-view="book"]');
  await page.waitForSelector('#bookList .item');
  const bookCount = (await page.$$('#bookList .item')).length;
  console.log(`错题本: ${bookCount} 条`);
  await page.screenshot({ path: `${shots}/ui_book.png`, fullPage: true });

  // ── 4) 复习 ──
  await page.click('[data-view="review"]');
  await page.waitForTimeout(500);
  const dueCount = (await page.$$('#dueList .item')).length;
  console.log(`复习队列: ${dueCount} 条`);
  await page.screenshot({ path: `${shots}/ui_review.png`, fullPage: true });

  console.log('UI E2E 完成');
  await b.close();
})().catch((e) => { console.error('失败:', e.message); process.exit(1); });

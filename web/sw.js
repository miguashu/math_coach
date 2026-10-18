/* 小学数学辅导 —— Service Worker
 *
 * 只做一件事：把「页面外壳」（HTML/CSS/JS/图标）缓存下来，
 * 让 iPhone 添加到主屏幕后即使服务暂时连不上，也能看到界面而不是白屏。
 *
 * 两条刻意的规则：
 *   1. /api/ 一律不缓存。题目、判分、错题本都必须走服务端实时算，
 *      缓存了会让家长看到过期的错题本 —— 那比白屏更糟。
 *   2. 缓存里没有的东西先走网络，网络成功就顺手存一份（stale-while-revalidate 的简化版）。
 *
 * 注意：Service Worker 只在「安全上下文」注册 —— HTTPS 或 localhost。
 * 手机上通过局域网 http://192.168.x.x 打开时浏览器不会注册它，
 * 这时「添加到主屏幕」仍然可用（那一步不依赖 SW），只是没有离线外壳。
 */

const CACHE = 'mathcoach-shell-v1';

const SHELL = [
  '/',
  '/index.html',
  '/app.css',
  '/app.js',
  '/manifest.webmanifest',
  '/icons/icon-192.png',
  '/icons/apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      // 逐个 add：任何一个 404 都不该让整个 install 失败
      .then((c) => Promise.all(SHELL.map((u) => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // 数据接口永远走网络：错题本、复习队列不能给旧数据
  if (url.pathname.startsWith('/api/')) return;

  event.respondWith(
    caches.match(req).then((hit) => {
      if (hit) return hit;
      return fetch(req)
        .then((res) => {
          if (res && res.ok && res.type === 'basic') {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
          }
          return res;
        })
        .catch(() => caches.match('/index.html'));
    }),
  );
});

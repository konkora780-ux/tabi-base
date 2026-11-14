// 旅ベース Service Worker（通知の受信・画面を開く・オフライン用の保存）
const VERSION = 'tabi-app-v0.4.1';
const SHELL = [
  './',
  './index.html',
  './push-test.html',
  './manifest.webmanifest',
  './lib/supabase-2.117.3.js',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/badge-72.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key !== VERSION) await caches.delete(key);
    await self.clients.claim();
  })());
});

// 画面はネット優先・つながらなければ保存した物を使う
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith((async () => {
    try {
      const res = await fetch(req);
      if (res.ok) (await caches.open(VERSION)).put(req, res.clone());
      return res;
    } catch {
      const hit = await caches.match(req, { ignoreSearch: req.mode === 'navigate' });
      return hit || caches.match('./index.html');
    }
  })());
});

// 端末内の受信記録（IndexedDB）… 画面の「この端末で受け取った通知」に表示する
function idb() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open('tabi-push-test', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('log', { keyPath: 'key' });
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
async function logLocal(entry) {
  try {
    const db = await idb();
    await new Promise((resolve) => {
      const tx = db.transaction('log', 'readwrite');
      tx.objectStore('log').put(entry);
      tx.oncomplete = tx.onerror = () => resolve();
    });
  } catch { /* 記録できなくても通知表示は続ける */ }
}

async function report(data, kind) {
  if (!data || !data.r || !data.d || !data.t) return;
  try {
    await fetch(data.r, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'receipt', d: data.d, t: data.t, kind }),
    });
  } catch { /* 圏外などで報告できない場合もある（通知自体は表示済み） */ }
}

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { title: '旅ベース', body: event.data ? event.data.text() : '' }; }
  const title = data.title || '旅ベース';
  const options = {
    body: data.body || '',
    icon: './icons/icon-192.png',
    badge: './icons/badge-72.png',
    tag: data.tag || undefined,      // 同じ通知が2回届いても1つにまとめる
    renotify: false,
    data,
  };
  // iPhoneでは、届いた通知は必ず表示しないと通知を止められることがあるため、常に表示する
  event.waitUntil(Promise.all([
    self.registration.showNotification(title, options),
    logLocal({ key: (data.d || data.nid || Date.now()) + ':received', at: new Date().toISOString(), title, kind: 'received' }),
    report(data, 'received'),
  ]));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const target = new URL(data.url || './', self.registration.scope);
  target.searchParams.set('from', 'push');
  if (data.nid) target.searchParams.set('nid', data.nid);
  event.waitUntil((async () => {
    await Promise.all([
      report(data, 'clicked'),
      logLocal({ key: (data.d || data.nid || Date.now()) + ':clicked', at: new Date().toISOString(), title: event.notification.title, kind: 'clicked' }),
    ]);
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope) && 'focus' in c) {
        try { await c.navigate(target.href); } catch { /* iPhoneで失敗することがある */ }
        return c.focus();
      }
    }
    return self.clients.openWindow(target.href);
  })());
});

// 端末の登録情報がブラウザ側で更新されたときは、次回画面を開いたときに再登録する
self.addEventListener('pushsubscriptionchange', () => {
  logLocal({ key: Date.now() + ':subchange', at: new Date().toISOString(), title: '端末の登録情報が変わりました', kind: 'subchange' });
});

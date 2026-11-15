// オフライン閲覧の画面テスト（偽のサーバー＋電波なしの再現）
const { chromium, devices } = require('playwright');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
(async () => {
  const b = await chromium.launch();
  const now = Math.floor(Date.now()/1000);
  const TODAY = new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,10);
  const iso = (min) => new Date(Date.now()+min*60000).toISOString();
  const trip = (id, name) => ({ id, name, start_date:TODAY, end_date:TODAY, timezone:'Asia/Tokyo', secret_scope:'editors', version:1, deleted_at:null });
  const db = { tabi_trips: [trip('T1','盛岡日帰り'), trip('T2','仙台')],
    tabi_members: [{ trip_id:'T1', user_id:'u1', role:'owner', display_name:'こんちゃん', joined_at:'1' }, { trip_id:'T2', user_id:'u1', role:'viewer', display_name:'こんちゃん', joined_at:'1' }],
    tabi_trip_invitations: [], tabi_push_subscriptions: [],
    tabi_segments: [{ id:'s1', trip_id:'T1', mode:'shinkansen', service_name:'はやぶさ1号', from_name:'盛岡', to_name:'東京', platform:'14', car_no:'5', seat:'3A', depart_at:iso(40), arrive_at:iso(180), depart_tz:'Asia/Tokyo', arrive_tz:'Asia/Tokyo', status:'scheduled', deleted_at:null, details:{} }],
    tabi_events: [{ id:'e1', trip_id:'T2', category:'meal', name:'牛たん', start_at:iso(300), timezone:'Asia/Tokyo', status:'scheduled', deleted_at:null }],
    tabi_trip_secrets: [{ id:'x1', trip_id:'T1', target_type:'segment', target_id:'s1', kind:'reservation', value:'SECRET-ABC123' }] };
  let down = false;
  const ctx = await b.newContext({ ...devices['iPhone 13'] });
  const p = await ctx.newPage(); const errs = [];
  p.on('pageerror', e => errs.push(e.message));
  const jwt = b64({alg:'HS256'})+'.'+b64({sub:'u1',email:'kon@x.jp',exp:now+3600})+'.s';
  const match = (row, u) => { for (const [k, v] of u.searchParams) { if (['select','order','limit','or'].includes(k)) continue;
    if (v.startsWith('eq.') && String(row[k]) !== v.slice(3)) return false; if (v === 'is.null' && row[k] != null) return false;
    if (v.startsWith('in.(') && !v.slice(4,-1).split(',').map(x=>x.replace(/"/g,'')).includes(String(row[k]))) return false; } return true; };
  await ctx.route('**/hortngwcijhjagwmcoxo.supabase.co/**', async (route) => {
    if (down) return route.abort('internetdisconnected');
    const r = route.request(); const u = new URL(r.url()); const m = r.method();
    const J = (o, st=200) => route.fulfill({status: st, contentType:'application/json', body: JSON.stringify(o)});
    if (u.pathname.includes('/auth/v1/verify')) return J({access_token:jwt, token_type:'bearer', expires_in:3600, expires_at:now+3600, refresh_token:'r', user:{id:'u1', email:'kon@x.jp'}});
    if (u.pathname.includes('/auth/v1/')) return J({});
    if (u.pathname.includes('/functions/')) return J({});
    const tbl = u.pathname.split('/').pop(); const rows = db[tbl]; if (!rows) return J([]);
    const single = (r.headers()['accept']||'').includes('vnd.pgrst.object');
    let hit = rows.filter(x => match(x, u));
    const mine = (id) => db.tabi_members.some(x => x.trip_id === id && x.user_id === 'u1');
    hit = hit.filter(x => tbl === 'tabi_trips' ? mine(x.id) : x.trip_id ? mine(x.trip_id) : true);
    if (m === 'DELETE') return J([]);
    let out = hit;
    if (tbl === 'tabi_trips') out = hit.map(t => ({ ...t, tabi_members: db.tabi_members.filter(x => x.trip_id === t.id) }));
    return J(single ? out[0] || null : out);
  });
  const txt = async (sel) => (await p.locator(sel).innerText()).replace(/\n+/g, ' | ');
  const go = async (h, w = 900) => { await p.evaluate((h) => location.hash = h, h); await p.waitForTimeout(w); };
  const dumpIdb = () => p.evaluate(async () => (await indexedDB.databases()).some(d => d.name === 'tabi-base') ? new Promise((res) => { const r = indexedDB.open('tabi-base'); r.onsuccess = () => { const db = r.result;
    if (!db.objectStoreNames.contains('snap')) { db.close(); return res([]); }
    const q = db.transaction('snap').objectStore('snap').getAll(); q.onsuccess = () => { db.close(); res(q.result); }; }; }) : []);

  await p.goto('http://127.0.0.1:8090/'); await p.waitForTimeout(800);
  await p.fill('#email', 'kon@x.jp'); await p.click('#btnSendCode'); await p.fill('#code', '123456'); await p.click('#btnVerify'); await p.waitForTimeout(2000);
  await go('#/trip/T1', 1200);
  let snap = await dumpIdb();
  console.log('IDB keys:', snap.map(x => x.key).sort().join(','), '| secret in IDB?', JSON.stringify(snap).includes('SECRET-ABC123'));

  // 電波なし
  down = true; await ctx.setOffline(true); await p.waitForTimeout(500);
  console.log('status:', await txt('#statusBar'));
  await go('#/trips'); console.log('OFF trips:', await txt('#tripsUpcoming'));
  await go('#/trip/T1'); console.log('OFF trip:', await txt('#tripMsg'), '|| segs:', await txt('#tripSegs'));
  console.log('OFF scope select:', await p.locator('#scopeQuick').count(), '|', await txt('#tripInfo'));
  console.log('OFF edit links:', await p.locator('#tripSegs a, #tripAddBtns a, #tripActions a, #tripActions button, #inviteBox:not(.hidden)').count(), '| buttons in segs:', await p.locator('#tripSegs button').count());
  await go('#/seg/T1/new', 400); console.log('OFF seg form:', await p.locator('#viewOffline').isVisible(), await p.locator('#viewSeg').isVisible());
  await go('#/home', 1200); console.log('OFF home:', await txt('#nextCard'));
  await p.screenshot({ path: '/var/tmp/offline-home.png' });
  // 再読み込み（Service Workerの保存から開く）
  await p.reload(); await p.waitForTimeout(1500); await go('#/trip/T2'); console.log('OFF reload T2:', await txt('#tripTitle'), '|', await txt('#tripSegs'));
  // ログインの更新ができない状態（保存したログイン情報が使えない）でも見られる
  await p.evaluate(() => { for (const k of Object.keys(localStorage)) if (k.startsWith('sb-')) localStorage.removeItem(k); });
  await p.reload(); await p.waitForTimeout(1500); await go('#/trips'); console.log('OFF no session trips visible:', await p.locator('#viewTrips').isVisible(), (await txt('#tripsUpcoming')).slice(0, 60));
  // 6時間以上前
  await p.evaluate(() => localStorage.setItem('tabi.lastSyncAt', new Date(Date.now() - 7 * 3600000).toISOString())); await go('#/home', 300);
  console.log('stale status:', await txt('#statusBar'));

  // 電波が戻る（ログインもし直し）→ T2 から外されていた → 端末の保存から消える
  await p.evaluate(() => localStorage.setItem('tabi.lastSyncAt', new Date().toISOString()));
  await p.reload(); // セッションなしのまま
  db.tabi_members = db.tabi_members.filter(x => x.trip_id !== 'T2');
  down = false; await ctx.setOffline(false); await p.waitForTimeout(2000);
  console.log('ON no session -> login view:', await p.locator('#viewLogin').isVisible(), '| IDB:', (await dumpIdb()).length);
  await p.fill('#email', 'kon@x.jp'); await p.click('#btnSendCode'); await p.fill('#code', '123456'); await p.click('#btnVerify'); await p.waitForTimeout(2500);
  // 保存がある状態で T1 も外される → 電波復帰時に消える
  await go('#/trips', 1500);
  console.log('ON IDB keys:', (await dumpIdb()).map(x => x.key).sort().join(','));
  db.tabi_members = [];
  await ctx.setOffline(true); await p.waitForTimeout(300); await ctx.setOffline(false); await p.waitForTimeout(2500);
  console.log('after removed from all, IDB keys:', (await dumpIdb()).map(x => x.key).sort().join(','));
  // ログアウトで端末データが消える
  db.tabi_members = [{ trip_id:'T1', user_id:'u1', role:'owner', display_name:'こんちゃん', joined_at:'1' }];
  await go('#/trips', 1500);
  await go('#/settings', 300); await p.locator('#btnLogout').dispatchEvent('click'); await p.waitForTimeout(200); await p.locator('#btnLogout').dispatchEvent('click'); await p.waitForTimeout(2000);
  console.log('after logout dbs:', JSON.stringify(await p.evaluate(async () => (await indexedDB.databases()).map(d => d.name))), 'ls:', await p.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('tabi.')).join(',')));
  console.log('errors:', errs);
  await b.close();
})();

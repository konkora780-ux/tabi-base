// 予約番号の閲覧範囲の画面テスト（偽のサーバーで、閲覧範囲のRLSを真似する）
const { chromium, devices } = require('playwright');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
(async () => {
  const b = await chromium.launch();
  const now = Math.floor(Date.now()/1000);
  const TODAY = new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,10);
  const db = { tabi_trips: [{ id:'T1', name:'盛岡日帰り', start_date:TODAY, end_date:TODAY, timezone:'Asia/Tokyo', secret_scope:'editors', version:1, deleted_at:null }],
    tabi_members: [{ trip_id:'T1', user_id:'u1', role:'owner', display_name:'こんちゃん' }, { trip_id:'T1', user_id:'u2', role:'viewer', display_name:'妻' }],
    tabi_trip_invitations: [], tabi_events: [],
    tabi_segments: [{ id:'s1', trip_id:'T1', mode:'shinkansen', service_name:'はやぶさ1号', from_name:'盛岡', to_name:'東京', depart_at:new Date(Date.now()+864e5).toISOString(), arrive_at:new Date(Date.now()+864e5+8e6).toISOString(), depart_tz:'Asia/Tokyo', arrive_tz:'Asia/Tokyo', status:'scheduled', deleted_at:null, details:{} }],
    tabi_trip_secrets: [{ id:'x1', trip_id:'T1', target_type:'segment', target_id:'s1', kind:'reservation', value:'ABC123' }] };
  const canSee = (uid) => { const m = db.tabi_members.find(x => x.user_id === uid); return m && (m.role !== 'viewer' || db.tabi_trips[0].secret_scope === 'all'); };
  async function page(uid, email) {
    const ctx = await b.newContext({ ...devices['iPhone 13'] });
    const p = await ctx.newPage(); p.errs = [];
    p.on('pageerror', e => p.errs.push(e.message)); p.on('console', m => m.type()==='error' && p.errs.push(m.text()));
    const jwt = b64({alg:'HS256'})+'.'+b64({sub:uid,email,exp:now+3600})+'.s';
    const match = (row, u) => { for (const [k, v] of u.searchParams) { if (['select','order','limit'].includes(k)) continue;
      if (v.startsWith('eq.') && String(row[k]) !== v.slice(3)) return false; if (v === 'is.null' && row[k] != null) return false; } return true; };
    await p.route('**/hortngwcijhjagwmcoxo.supabase.co/**', async (route) => {
      const r = route.request(); const u = new URL(r.url()); const m = r.method();
      const J = (o, st=200) => route.fulfill({status: st, contentType:'application/json', body: JSON.stringify(o)});
      if (u.pathname.includes('/auth/v1/verify')) return J({access_token:jwt, token_type:'bearer', expires_in:3600, expires_at:now+3600, refresh_token:'r', user:{id:uid, email}});
      if (u.pathname.includes('/auth/v1/')) return J({});
      const tbl = u.pathname.split('/').pop(); const rows = db[tbl];
      if (!rows) return J(null);
      const single = (r.headers()['accept']||'').includes('vnd.pgrst.object');
      let hit = rows.filter(x => match(x, u));
      if (tbl === 'tabi_trip_secrets' && !canSee(uid)) hit = []; // RLS: 見られない人にはデータを送らない
      if (m === 'PATCH') { const body = JSON.parse(r.postData());
        if (tbl === 'tabi_trips' && 'secret_scope' in body && db.tabi_members.find(x => x.user_id === uid).role !== 'owner') return J({ message:'予約番号の閲覧範囲を変えられるのは作成者だけです' }, 400);
        hit.forEach(x => { Object.assign(x, body); if ('version' in x) x.version++; }); return J(hit); }
      let out = hit;
      if (tbl === 'tabi_trips') out = hit.map(t => ({ ...t, tabi_members: db.tabi_members.filter(x => x.trip_id === t.id) }));
      return J(single ? out[0] || null : out);
    });
    await p.goto('http://127.0.0.1:8090/'); await p.waitForTimeout(600);
    await p.fill('#email', email); await p.click('#btnSendCode'); await p.fill('#code', '123456'); await p.click('#btnVerify'); await p.waitForTimeout(1000);
    return p;
  }
  const txt = async (p, sel) => (await p.locator(sel).innerText()).replace(/\n+/g, ' | ');
  const open = async (p) => { await p.goto('http://127.0.0.1:8090/#/trips'); await p.waitForTimeout(300); await p.goto('http://127.0.0.1:8090/#/trip/T1'); await p.waitForTimeout(1000); };

  const V = await page('u2', 'v@x.jp'); await open(V);
  console.log('V info (editors):', await txt(V, '#tripInfo'));
  console.log('V secret buttons:', await V.locator('#tripSegs button').count(), '| scope select:', await V.locator('#scopeQuick').count());

  const O = await page('u1', 'o@x.jp'); await open(O);
  console.log('O secret buttons:', await O.locator('#tripSegs button').count());
  await O.selectOption('#scopeQuick', 'all'); await O.waitForTimeout(1200);
  console.log('O msg:', await txt(O, '#tripMsg'), '| db scope:', db.tabi_trips[0].secret_scope, 'version:', db.tabi_trips[0].version);
  await O.screenshot({ path: '/var/tmp/scope-owner.png' });

  await open(V);
  console.log('V info (all):', await txt(V, '#tripInfo'));
  await V.locator('#tripSegs button').first().dispatchEvent('click'); await V.waitForTimeout(600);
  console.log('V sees:', await txt(V, '#tripSegs'));

  // 閲覧者が画面を開いたまま、作成者が範囲を戻す → 表示を押しても見えない
  await open(V);
  db.tabi_trips[0].version = 99; // 古い版のまま作成者が切り替える → 衝突を検出
  await O.selectOption('#scopeQuick', 'editors'); await O.waitForTimeout(1200);
  console.log('O stale:', await txt(O, '#tripMsg'), '| db scope:', db.tabi_trips[0].secret_scope);
  await O.selectOption('#scopeQuick', 'editors'); await O.waitForTimeout(1200);
  console.log('O retry:', await txt(O, '#tripMsg'), '| db scope:', db.tabi_trips[0].secret_scope);
  await V.locator('#tripSegs button').first().dispatchEvent('click'); await V.waitForTimeout(600);
  console.log('V after revoke:', await txt(V, '#tripSegs'));
  console.log('errors:', O.errs, V.errs);
  await b.close();
})();

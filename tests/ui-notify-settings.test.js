// 予約番号の閲覧範囲の画面テスト（偽のサーバーで、閲覧範囲のRLSを真似する）
const { chromium, devices } = require('playwright');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
(async () => {
  const b = await chromium.launch();
  const now = Math.floor(Date.now()/1000);
  const TODAY = new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,10);
  const db = { tabi_trips: [{ id:'T1', name:'盛岡日帰り', start_date:TODAY, end_date:TODAY, timezone:'Asia/Tokyo', secret_scope:'editors', version:1, deleted_at:null }],
    tabi_members: [{ trip_id:'T1', user_id:'u1', role:'owner', display_name:'こんちゃん' }, { trip_id:'T1', user_id:'u2', role:'viewer', display_name:'妻' }],
    tabi_trip_invitations: [], tabi_events: [], tabi_notification_rules: [],
    tabi_notifications: [{ trip_id:'T1', status:'scheduled', title:'🚄 30分後に出発：はやぶさ1号', send_at:new Date(Date.now()+3600e3).toISOString() }],
    tabi_segments: [{ id:'s1', trip_id:'T1', mode:'shinkansen', service_name:'はやぶさ1号', from_name:'盛岡', to_name:'東京', depart_at:new Date(Date.now()+864e5).toISOString(), arrive_at:new Date(Date.now()+864e5+8e6).toISOString(), depart_tz:'Asia/Tokyo', arrive_tz:'Asia/Tokyo', status:'scheduled', deleted_at:null, details:{} }],
    tabi_trip_secrets: [{ id:'x1', trip_id:'T1', target_type:'segment', target_id:'s1', kind:'reservation', value:'ABC123' }] };
  const canSee = (uid) => { const m = db.tabi_members.find(x => x.user_id === uid); return m && (m.role !== 'viewer' || db.tabi_trips[0].secret_scope === 'all'); };
  async function page(uid, email) {
    const ctx = await b.newContext({ ...devices['iPhone 13'] });
    const p = await ctx.newPage(); p.errs = [];
    p.on('pageerror', e => p.errs.push(e.message)); p.on('console', m => m.type()==='error' && p.errs.push(m.text()));
    const jwt = b64({alg:'HS256'})+'.'+b64({sub:uid,email,exp:now+3600})+'.s';
    const match = (row, u) => { for (const [k, v] of u.searchParams) { if (['select','order','limit','on_conflict','send_at'].includes(k)) continue;
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
      if (m === 'POST' && tbl === 'tabi_notification_rules') { const body = [].concat(JSON.parse(r.postData()));
        if (db.tabi_members.find(x => x.user_id === uid).role === 'viewer') return J({ message:'new row violates row-level security policy' }, 403);
        for (const b of body) { const i = rows.findIndex(x => x.trip_id === b.trip_id && x.kind === b.kind); if (i >= 0) rows[i] = b; else rows.push(b); }
        p.posts = (p.posts || 0) + 1; return J(body, 201); }
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
  const open = async (p) => { await p.goto('http://127.0.0.1:8090/#/trips'); await p.waitForTimeout(300); await p.goto('http://127.0.0.1:8090/#/trip/T1'); await p.waitForTimeout(1200); };
  const O = await page('u1', 'o@x.jp'); await open(O);
  console.log('O notify:', await txt(O, '#notifyBox'));
  await O.locator('[data-nk="arrive"]').uncheck(); await O.selectOption('[data-nm="depart"]', '15'); await O.selectOption('[data-nm="day_before"]', '1260');
  await O.locator('#btnSaveNotify').dispatchEvent('click'); await O.waitForTimeout(1200);
  console.log('O saved:', await txt(O, '#notifyMsg'), '| db:', JSON.stringify(db.tabi_notification_rules.map(r => [r.kind, r.enabled, r.minutes])));
  console.log('O after reload arrive checked:', await O.locator('[data-nk="arrive"]').isChecked(), 'depart:', await O.inputValue('[data-nm="depart"]'));
  await O.locator('#notifyBox').screenshot({ path: '/var/tmp/notify-owner.png' });
  const V = await page('u2', 'v@x.jp'); await open(V);
  console.log('V notify:', await txt(V, '#notifyRules'), '| disabled:', await V.locator('[data-nk="depart"]').isDisabled(), '| save btn:', await V.locator('#btnSaveNotify').count());
  console.log('errors:', O.errs, V.errs);
  await b.close();
})();

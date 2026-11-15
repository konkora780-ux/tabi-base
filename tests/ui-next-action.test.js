const { chromium, devices } = require('playwright');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPhone 13'] });
  const p = await ctx.newPage(); const errs = [];
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => m.type()==='error' && errs.push(m.text()));
  const now = Math.floor(Date.now()/1000);
  const jwt = b64({alg:'HS256'})+'.'+b64({sub:'u1',email:'t@x.jp',exp:now+3600})+'.s';
  const TODAY = new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,10);
  const iso = (min) => new Date(Date.now()+min*60000).toISOString();
  const db = { tabi_trips: [{ id:'T1', name:'盛岡日帰り', start_date:TODAY, end_date:TODAY, timezone:'Asia/Tokyo', secret_scope:'editors', version:1, deleted_at:null }],
    tabi_members: [{ trip_id:'T1', user_id:'u1', role:'owner', display_name:'t' }], tabi_segments: [], tabi_events: [], tabi_trip_secrets: [] };
  let n = 0;
  const match = (row, u) => { for (const [k, v] of u.searchParams) { if (['select','order','limit'].includes(k)) continue;
      if (v.startsWith('eq.') && String(row[k]) !== v.slice(3)) return false; if (v === 'is.null' && row[k] != null) return false; } return true; };
  await p.route('**/hortngwcijhjagwmcoxo.supabase.co/**', async (route) => {
    const r = route.request(); const u = new URL(r.url()); const m = r.method();
    const J = (o, st=200) => route.fulfill({status: st, contentType:'application/json', body: JSON.stringify(o)});
    if (u.pathname.includes('/auth/v1/verify')) return J({access_token:jwt, token_type:'bearer', expires_in:3600, expires_at:now+3600, refresh_token:'r', user:{id:'u1', email:'t@x.jp'}});
    if (u.pathname.includes('/auth/v1/')) return J({});
    const tbl = u.pathname.split('/').pop(); const rows = db[tbl];
    if (!rows) return route.fulfill({status:204, body:''});
    const single = (r.headers()['accept']||'').includes('vnd.pgrst.object');
    if (m === 'POST') { const row = { id: tbl[5] + (++n), version: 1, deleted_at: null, details: {}, ...JSON.parse(r.postData()) }; rows.push(row); return J(single ? row : [row], 201); }
    const hit = rows.filter(x => match(x, u));
    if (m === 'PATCH') { const body = JSON.parse(r.postData()); hit.forEach(x => { Object.assign(x, body); x.version = (x.version||1)+1; }); return J(hit); }
    if (m === 'DELETE') { db[tbl] = rows.filter(x => !hit.includes(x)); return J([]); }
    let out = hit;
    if (tbl === 'tabi_trips') out = hit.map(t => ({ ...t, tabi_members: db.tabi_members.filter(x => x.trip_id === t.id) }));
    return J(single ? out[0] || null : out);
  });
  db.tabi_segments.push({ id:'s1', trip_id:'T1', mode:'shinkansen', service_name:'のぞみ12号', from_name:'新大阪', to_name:'東京', platform:'21', car_no:'7', seat:'12A', depart_at: iso(25), arrive_at: iso(170), depart_tz:'Asia/Tokyo', arrive_tz:'Asia/Tokyo', status:'scheduled', deleted_at:null, details:{} });
  db.tabi_events.push({ id:'e1', trip_id:'T1', category:'meal', name:'夕食', place_name:'東京駅', start_at: iso(200), end_at: iso(260), timezone:'Asia/Tokyo', status:'scheduled', deleted_at:null });
  db.tabi_events.push({ id:'e2', trip_id:'T1', category:'meal', name:'中止した予定', start_at: iso(10), timezone:'Asia/Tokyo', status:'cancelled', deleted_at:null });
  await p.goto('http://127.0.0.1:8090/'); await p.waitForTimeout(800);
  await p.fill('#email', 't@x.jp'); await p.click('#btnSendCode'); await p.fill('#code', '123456'); await p.click('#btnVerify'); await p.waitForTimeout(1500);
  console.log('NEXT:', (await p.locator('#nextCard').innerText()).replace(/\n/g,' | '));
  await p.screenshot({ path: '/var/tmp/home-next.png' });
  db.tabi_segments[0].depart_at = iso(-30);
  await p.goto('http://127.0.0.1:8090/#/trips'); await p.waitForTimeout(500); await p.goto('http://127.0.0.1:8090/#/home'); await p.waitForTimeout(1200);
  console.log('ONGOING:', (await p.locator('#nextCard').innerText()).replace(/\n/g,' | '));
  db.tabi_segments.length = 0; db.tabi_events.length = 0;
  await p.goto('http://127.0.0.1:8090/#/trips'); await p.waitForTimeout(500); await p.goto('http://127.0.0.1:8090/#/home'); await p.waitForTimeout(1200);
  console.log('EMPTY:', (await p.locator('#nextCard').innerText()).replace(/\n/g,' | '));
  console.log('errors:', errs);
  await b.close();
})();

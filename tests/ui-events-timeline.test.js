const { chromium, devices } = require('playwright');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPhone 13'] });
  const p = await ctx.newPage(); const errs = [];
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => m.type()==='error' && errs.push(m.text()));
  const now = Math.floor(Date.now()/1000);
  const jwt = b64({alg:'HS256'})+'.'+b64({sub:'u1',email:'t@x.jp',exp:now+3600})+'.s';
  const db = { tabi_trips: [{ id:'T1', name:'盛岡日帰り', start_date:'2026-12-01', end_date:'2026-12-01', timezone:'Asia/Tokyo', secret_scope:'editors', version:1, deleted_at:null }],
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
  await p.goto('http://127.0.0.1:8090/'); await p.waitForTimeout(800);
  await p.fill('#email', 't@x.jp'); await p.click('#btnSendCode'); await p.fill('#code', '123456'); await p.click('#btnVerify'); await p.waitForTimeout(600);
  await p.goto('http://127.0.0.1:8090/#/trip/T1'); await p.waitForTimeout(1200);
  console.log('trip segs empty:', await p.locator('#tripSegs').innerText());
  await p.goto('http://127.0.0.1:8090/#/seg/T1/new'); await p.waitForTimeout(1000);
  console.log('default mode fields:', (await p.locator('#segFields').innerText()).replace(/\n/g,' | '));
  await p.selectOption('#sMode', 'flight'); await p.waitForTimeout(100);
  console.log('flight fields:', (await p.locator('#segFields').innerText()).replace(/\n/g,' | '), 'dep label:', await p.locator('#sDepLabel').innerText());
  await p.selectOption('#sMode', 'shinkansen');
  await p.fill('[data-key=service_name]', 'はやぶさ12号'); await p.fill('[data-key=from_name]', '盛岡'); await p.fill('[data-key=to_name]', '東京');
  await p.fill('[data-key=platform]', '13'); await p.fill('[data-key=car_no]', '7'); await p.fill('[data-key=seat]', '12A'); await p.fill('[data-key="details.seat_type"]', '指定席');
  await p.fill('#sDep', '2026-12-01T14:03'); await p.fill('#sArr', '2026-12-01T16:20');
  await p.fill('#sResv', 'ABC123');
  await p.locator('#btnSaveSeg').dispatchEvent('click'); await p.waitForTimeout(1500);
  console.log('saved seg:', JSON.stringify(db.tabi_segments.map(x=>({mode:x.mode, dep:x.depart_at, arr:x.arrive_at, tz:x.depart_tz, details:x.details, plat:x.platform}))));
  console.log('secrets:', JSON.stringify(db.tabi_trip_secrets.map(x=>({kind:x.kind, value:x.value, target:x.target_id}))));
  console.log('trip page list:', (await p.locator('#tripSegs').innerText()).replace(/\n/g,' | '));
  await p.locator('#tripSegs button').dispatchEvent('click'); await p.waitForTimeout(500);
  console.log('after show secret:', (await p.locator('#tripSegs').innerText()).replace(/\n/g,' | '));
  await p.screenshot({ path: '/var/tmp/seg-list.png', fullPage: true });
  // 編集：海外の時間帯・キャンセル・予約番号削除
  await p.goto('http://127.0.0.1:8090/#/seg/T1/' + db.tabi_segments[0].id); await p.waitForTimeout(1000);
  console.log('edit prefilled dep:', await p.inputValue('#sDep'), 'resv:', await p.inputValue('#sResv'));
  await p.selectOption('#sStatus', 'cancelled'); await p.fill('#sResv', '');
  await p.locator('#btnSaveSeg').dispatchEvent('click'); await p.waitForTimeout(1200);
  console.log('after edit status/secrets:', db.tabi_segments[0].status, db.tabi_trip_secrets.length);
  console.log('list:', (await p.locator('#tripSegs').innerText()).replace(/\n/g,' | '));
  // ---- 予定 ----
  await p.goto('http://127.0.0.1:8090/#/ev/T1/new'); await p.waitForTimeout(1000);
  await p.locator('#btnSaveEv').dispatchEvent('click'); await p.waitForTimeout(200); console.log('ev no name:', await p.locator('#evMsg').innerText());
  await p.selectOption('#eCat', 'stay'); console.log('stay labels:', await p.locator('#eStartLabel').innerText(), await p.locator('#eEndLabel').innerText(), await p.locator('#eNameLabel').innerText());
  await p.fill('#eName', '盛岡ホテル'); await p.fill('#ePlace', '盛岡駅前'); await p.fill('#eStart', '2026-12-01T15:00'); await p.fill('#eEnd', '2026-12-02T10:00'); await p.fill('#eResv', 'H-999');
  await p.locator('#btnSaveEv').dispatchEvent('click'); await p.waitForTimeout(1200);
  await p.goto('http://127.0.0.1:8090/#/ev/T1/new'); await p.waitForTimeout(1000);
  await p.selectOption('#eCat', 'meal'); await p.fill('#eName', '昼食（わんこそば）'); await p.fill('#eStart', '2026-12-01T12:00'); await p.fill('#eEnd', '2026-12-01T13:00');
  await p.locator('#btnSaveEv').dispatchEvent('click'); await p.waitForTimeout(1200);
  console.log('events saved:', JSON.stringify(db.tabi_events.map(x=>({c:x.category,n:x.name,s:x.start_at,e:x.end_at}))));
  console.log('timeline:', (await p.locator('#tripSegs').innerText()).replace(/\n/g,' | '));
  await p.screenshot({ path: '/var/tmp/timeline.png', fullPage: true });
  console.log('errors:', errs);
  await b.close();
})();

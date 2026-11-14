const { chromium, devices } = require('playwright');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPhone 13'] });
  const p = await ctx.newPage(); const errs = []; const calls = [];
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => m.type()==='error' && errs.push(m.text()));
  const now = Math.floor(Date.now()/1000);
  const jwt = b64({alg:'HS256'})+'.'+b64({sub:'u1',email:'t@x.jp',exp:now+3600,role:'authenticated'})+'.s';
  const trips = []; const members = [];
  let conflict = false;
  await p.route('**/hortngwcijhjagwmcoxo.supabase.co/**', async (route) => {
    const r = route.request(); const u = new URL(r.url()); const m = r.method();
    calls.push(m + ' ' + u.pathname + u.search);
    const J = (o, st=200) => route.fulfill({status: st, contentType:'application/json', body: JSON.stringify(o)});
    if (u.pathname.includes('/auth/v1/verify')) return J({access_token:jwt, token_type:'bearer', expires_in:3600, expires_at:now+3600, refresh_token:'r', user:{id:'u1', email:'t@x.jp'}});
    if (u.pathname.includes('/auth/v1/')) return J({});
    if (u.pathname.endsWith('/tabi_trips')) {
      const accept = r.headers()['accept'] || '';
      const single = accept.includes('vnd.pgrst.object');
      if (m === 'POST') { const row = { ...JSON.parse(r.postData()), id: 'trip' + (trips.length+1), version: 1, deleted_at: null, secret_scope: JSON.parse(r.postData()).secret_scope || 'editors' };
        trips.push(row); members.push({ trip_id: row.id, user_id: 'u1', role: 'owner', display_name: 't' }); return J(single ? { id: row.id } : [{ id: row.id }], 201); }
      if (m === 'PATCH') { const id = u.searchParams.get('id').slice(3); const t = trips.find(x => x.id === id);
        const ver = u.searchParams.get('version');
        if (!t || (ver && (conflict || Number(ver.slice(3)) !== t.version))) return J([]);
        Object.assign(t, JSON.parse(r.postData())); t.version++; return J([{ id }]); }
      const idq = u.searchParams.get('id');
      if (idq) { const t = trips.find(x => x.id === idq.slice(3)); return J(single ? t : (t ? [t] : []), single && !t ? 406 : 200); }
      return J(trips.filter(t => !t.deleted_at).map(t => ({ ...t, tabi_members: members.filter(x => x.trip_id === t.id) })));
    }
    if (u.pathname.endsWith('/tabi_members')) {
      const tid = u.searchParams.get('trip_id').slice(3);
      const rows = members.filter(x => x.trip_id === tid);
      const single = (r.headers()['accept']||'').includes('vnd.pgrst.object');
      return J(single ? rows[0] : rows);
    }
    return route.fulfill({ status: 204, body: '' });
  });
  await p.goto('http://127.0.0.1:8090/'); await p.waitForTimeout(1000);
  await p.fill('#email', 't@x.jp'); await p.click('#btnSendCode'); await p.fill('#code', '123456'); await p.click('#btnVerify'); await p.waitForTimeout(800);
  console.log('home next:', (await p.locator('#nextCard').innerText()).replace(/\n/g,' / '));
  await p.click('a[data-view=trips]'); await p.waitForTimeout(500);
  console.log('trips empty:', (await p.locator('#tripsUpcoming').innerText()));
  await p.click('#viewTrips a.btn'); await p.waitForTimeout(300);
  await p.locator('#btnSaveTrip').dispatchEvent('click'); await p.waitForTimeout(200); console.log('no name msg:', await p.locator('#editMsg').innerText());
  await p.fill('#fName', '盛岡日帰り'); await p.fill('#fStart', '2026-12-05'); await p.fill('#fEnd', '2026-12-04');
  await p.locator('#btnSaveTrip').dispatchEvent('click'); await p.waitForTimeout(200); console.log('bad date msg:', await p.locator('#editMsg').innerText());
  await p.fill('#fEnd', '2026-12-05'); await p.fill('#fDest', '盛岡'); await p.selectOption('#fTz', 'Asia/Tokyo');
  await p.locator('#btnSaveTrip').dispatchEvent('click'); await p.waitForTimeout(800);
  console.log('hash after create:', await p.evaluate(()=>location.hash), 'title:', await p.locator('#tripTitle').innerText());
  console.log('info:', (await p.locator('#tripInfo').innerText()).replace(/\n/g,' / '));
  await p.screenshot({ path: '/var/tmp/trip-detail.png', fullPage: true });
  await p.locator('#tripActions a').dispatchEvent('click'); await p.waitForTimeout(600);
  console.log('edit prefilled:', await p.inputValue('#fName'), 'scope visible:', await p.locator('#scopeBox').isVisible());
  await p.fill('#fName', '盛岡日帰り（改）'); await p.locator('#btnSaveTrip').dispatchEvent('click'); await p.waitForTimeout(800);
  console.log('after edit title:', await p.locator('#tripTitle').innerText());
  // 競合
  await p.locator('#tripActions a').dispatchEvent('click'); await p.waitForTimeout(600); conflict = true;
  await p.fill('#fName', 'stale'); await p.locator('#btnSaveTrip').dispatchEvent('click'); await p.waitForTimeout(600);
  console.log('conflict msg:', await p.locator('#editMsg').innerText()); conflict = false;
  await p.locator('#editBack').dispatchEvent('click'); await p.waitForTimeout(600);
  await p.locator('#btnDeleteTrip').dispatchEvent('click'); await p.waitForTimeout(200); console.log('delete 1st:', await p.locator('#tripMsg').innerText());
  await p.locator('#btnDeleteTrip').dispatchEvent('click'); await p.waitForTimeout(800);
  console.log('after delete hash:', await p.evaluate(()=>location.hash), 'list:', await p.locator('#tripsUpcoming').innerText());
  await p.goto('http://127.0.0.1:8090/#/home'); await p.waitForTimeout(1000);
  console.log('errors:', errs);
  await b.close();
})();

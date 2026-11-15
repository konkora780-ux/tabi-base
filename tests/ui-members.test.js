// 招待・参加者管理の画面テスト（Supabaseは偽物で置き換え）
const { chromium, devices } = require('playwright');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
(async () => {
  const b = await chromium.launch();
  const now = Math.floor(Date.now()/1000);
  const TODAY = new Date(Date.now()-new Date().getTimezoneOffset()*60000).toISOString().slice(0,10);
  const db = { tabi_trips: [{ id:'T1', name:'盛岡日帰り', start_date:TODAY, end_date:TODAY, timezone:'Asia/Tokyo', secret_scope:'editors', version:1, deleted_at:null }],
    tabi_members: [{ trip_id:'T1', user_id:'u1', role:'owner', display_name:'こんちゃん' }, { trip_id:'T1', user_id:'u2', role:'viewer', display_name:'妻' }],
    tabi_trip_invitations: [], tabi_segments: [], tabi_events: [], tabi_trip_secrets: [] };
  const rpcLog = [];
  async function page(uid, email) {
    const ctx = await b.newContext({ ...devices['iPhone 13'], permissions: ['clipboard-read','clipboard-write'] });
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
      const tbl = u.pathname.split('/').pop();
      if (u.pathname.includes('/rpc/')) {
        const a = JSON.parse(r.postData() || '{}'); rpcLog.push([uid, tbl, a]);
        if (tbl === 'tabi_create_invitation') { const code = 'CODE' + 'x'.repeat(28) + db.tabi_trip_invitations.length;
          db.tabi_trip_invitations.push({ id:'I'+db.tabi_trip_invitations.length, trip_id:a.p_trip, code, role:a.p_role, created_at:new Date().toISOString(), expires_at:new Date(Date.now()+7*864e5).toISOString(), used_at:null, revoked_at:null });
          return J(code); }
        if (tbl === 'tabi_revoke_invitation') { db.tabi_trip_invitations.find(i => i.id === a.p_invitation).revoked_at = new Date().toISOString(); return J(null); }
        if (tbl === 'tabi_peek_invitation') { const i = db.tabi_trip_invitations.find(i => i.code === a.p_code);
          if (!i) return J([{ trip_name:null, role:null, status:'invalid' }]);
          if (db.tabi_members.some(x => x.trip_id === i.trip_id && x.user_id === uid)) return J([{ trip_name:'盛岡日帰り', role:i.role, status:'already_member' }]);
          return J([{ trip_name:'盛岡日帰り', role:i.role, status: i.revoked_at ? 'revoked' : i.used_at ? 'used' : 'ok' }]); }
        if (tbl === 'tabi_accept_invitation') { const i = db.tabi_trip_invitations.find(i => i.code === a.p_code);
          if (!i || i.used_at || i.revoked_at) return J({ message:'この招待リンクはすでに使われています' }, 400);
          i.used_at = new Date().toISOString(); db.tabi_members.push({ trip_id:i.trip_id, user_id:uid, role:i.role, display_name:a.p_display_name }); return J(i.trip_id); }
        if (tbl === 'tabi_transfer_owner') { db.tabi_members.forEach(x => { if (x.user_id === uid) x.role = 'editor'; if (x.user_id === a.p_new_owner) x.role = 'owner'; }); return J(null); }
        return J(null);
      }
      const rows = db[tbl]; if (!rows) return route.fulfill({status:204, body:''});
      const single = (r.headers()['accept']||'').includes('vnd.pgrst.object');
      const hit = rows.filter(x => match(x, u));
      if (m === 'PATCH') { const body = JSON.parse(r.postData()); hit.forEach(x => Object.assign(x, body)); return J(hit); }
      if (m === 'DELETE') { db[tbl] = rows.filter(x => !hit.includes(x)); return J(hit); }
      let out = tbl === 'tabi_trip_invitations' ? hit.map(({code, ...x}) => x) : hit; // コードそのものはサーバーにない
      if (tbl === 'tabi_trips') out = hit.filter(t => db.tabi_members.some(x => x.trip_id === t.id && x.user_id === uid)).map(t => ({ ...t, tabi_members: db.tabi_members.filter(x => x.trip_id === t.id) }));
      return J(single ? out[0] || null : out);
    });
    p.login = async () => { await p.fill('#email', email); await p.click('#btnSendCode'); await p.fill('#code', '123456'); await p.click('#btnVerify'); await p.waitForTimeout(1200); };
    return p;
  }
  const click = (p, sel) => p.locator(sel).first().dispatchEvent('click');
  const txt = async (p, sel) => (await p.locator(sel).innerText()).replace(/\n+/g, ' | ');

  // 作成者：招待リンクを作る
  const A = await page('u1', 'kon@x.jp');
  await A.goto('http://127.0.0.1:8090/'); await A.waitForTimeout(600); await A.login();
  await A.goto('http://127.0.0.1:8090/#/trip/T1'); await A.waitForTimeout(1000);
  console.log('A members:', await txt(A, '#tripMembers'));
  console.log('A leave:', await txt(A, '#leaveBox'));
  await A.selectOption('#invRole', 'editor'); await click(A, '#btnInvite'); await A.waitForTimeout(800);
  const url = await A.inputValue('#invUrl'); console.log('invite url:', url);
  console.log('A invList:', await txt(A, '#invList'));
  await A.screenshot({ path: '/var/tmp/inv-owner.png', fullPage: true });

  // 招待された人：ログイン前にリンクを開く → ログイン → 参加
  const B = await page('u3', 'tomo@x.jp');
  await B.goto(url.replace('https://konkora780-ux.github.io/tabi-base/', 'http://127.0.0.1:8090/')); await B.waitForTimeout(800);
  console.log('B before login invite note visible:', await B.locator('#loginInvite').isVisible());
  await B.login(); await B.waitForTimeout(800);
  console.log('B hash after login:', await B.evaluate(() => location.hash.slice(0, 12)));
  console.log('B join info:', await txt(B, '#joinInfo'));
  await B.fill('#joinName', 'ともだち'); await click(B, '#btnJoin'); await B.waitForTimeout(1200);
  console.log('B hash after join:', await B.evaluate(() => location.hash), 'members:', await txt(B, '#tripMembers'));
  console.log('B inviteBox hidden:', await B.locator('#inviteBox').isHidden(), 'leave btn:', await B.locator('#btnLeave').count());
  await B.screenshot({ path: '/var/tmp/inv-joined.png', fullPage: true });

  // 同じリンクをもう一度（別の人）→ 使用済み
  const C = await page('u4', 'c@x.jp');
  await C.goto('http://127.0.0.1:8090/'); await C.waitForTimeout(600); await C.login();
  await C.goto('http://127.0.0.1:8090/#/trips'); await C.waitForTimeout(600);
  await C.fill('#joinPaste', url); await click(C, '#btnJoinPaste'); await C.waitForTimeout(1000);
  console.log('C used link:', await txt(C, '#joinInfo'), 'form hidden:', await C.locator('#joinForm').isHidden());
  await C.goto('http://127.0.0.1:8090/#/trips'); await C.waitForTimeout(500);
  await C.fill('#joinPaste', 'abc'); await click(C, '#btnJoinPaste'); await C.waitForTimeout(300);
  console.log('C bad paste:', await txt(C, '#joinPasteMsg'));

  // 作成者：無効化・権限変更・外す
  await A.goto('http://127.0.0.1:8090/#/trips'); await A.waitForTimeout(300);
  await A.goto('http://127.0.0.1:8090/#/trip/T1'); await A.waitForTimeout(1000);
  await A.selectOption('#invRole', 'viewer'); await click(A, '#btnInvite'); await A.waitForTimeout(800);
  await click(A, '[data-revoke]'); await A.waitForTimeout(800);
  console.log('A invList after revoke:', await txt(A, '#invList'));
  await A.selectOption('[data-role="u2"]', 'editor'); await A.waitForTimeout(600);
  console.log('A role msg:', await txt(A, '#memberMsg'), 'db u2:', db.tabi_members.find(x => x.user_id==='u2').role);
  await click(A, '[data-remove="u2"]'); await A.waitForTimeout(200);
  console.log('A remove 1st:', await txt(A, '#memberMsg'), 'still:', db.tabi_members.some(x=>x.user_id==='u2'));
  await click(A, '[data-remove="u2"]'); await A.waitForTimeout(1000);
  console.log('A remove 2nd:', await txt(A, '#memberMsg'), 'still:', db.tabi_members.some(x=>x.user_id==='u2'));
  // 作成者を譲る
  await click(A, '[data-transfer="u3"]'); await A.waitForTimeout(200); await click(A, '[data-transfer="u3"]'); await A.waitForTimeout(1200);
  console.log('A after transfer:', await txt(A, '#memberMsg'), '| members:', await txt(A, '#tripMembers'), '| inviteBox hidden:', await A.locator('#inviteBox').isHidden());
  // 表示名変更
  await A.locator('#myNameBox summary').click(); await A.fill('#myName', 'こんちゃん2'); await click(A, '#btnMyName'); await A.waitForTimeout(1000);
  console.log('A name:', await txt(A, '#memberMsg'), db.tabi_members.find(x=>x.user_id==='u1').display_name);
  // 編集者になったAが抜ける
  await click(A, '#btnLeave'); await A.waitForTimeout(200); await click(A, '#btnLeave'); await A.waitForTimeout(1200);
  console.log('A after leave hash:', await A.evaluate(() => location.hash), 'trips:', await txt(A, '#tripsUpcoming'));
  console.log('rpc:', rpcLog.map(x => x[0]+':'+x[1]).join(', '));
  console.log('errors:', A.errs, B.errs, C.errs);
  await b.close();
})();

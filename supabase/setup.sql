-- =====================================================================
-- 旅ベース 通知の事前検証用 データベース設定
-- Supabase の「SQL Editor」に全文を貼り付けて「Run」で実行します。
-- 何度実行しても壊れないように書いてあります（作り直しではなく追加・更新）。
--
-- 作るもの
--   1. tabi_push_subscriptions       … 通知を受け取る端末の登録
--   2. tabi_notifications            … 送る予定の通知（テスト用）
--   3. tabi_notification_deliveries  … 端末ごとの送信記録（受付・受信・タップ・失敗・再試行）
--   4. RLS（本人のデータしか見られない・変えられない鍵）
--   5. 毎分動く Cron（予約時刻になった通知を送る）
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. 端末の登録
-- ---------------------------------------------------------------------
create table if not exists public.tabi_push_subscriptions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  endpoint         text not null unique,
  p256dh           text not null,
  auth             text not null,
  device_label     text,
  user_agent       text,
  is_active        boolean not null default true,
  failure_count    int not null default 0,
  last_success_at  timestamptz,
  last_failure_at  timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists tabi_push_subscriptions_user_idx on public.tabi_push_subscriptions(user_id);

-- ---------------------------------------------------------------------
-- 2. 通知（予定）
--   status: scheduled=予約中 / sending=送信中 / done=送信処理完了 / cancelled=取り消し
--   dedupe_key: 同じ予定の通知を見分ける名前。予定変更時に古い通知を取り消すのに使う
--   debug_fail_first: 再試行テスト用。1回目の送信をわざと失敗扱いにする
-- ---------------------------------------------------------------------
create table if not exists public.tabi_notifications (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title             text not null check (char_length(title) between 1 and 100),
  body              text not null default '' check (char_length(body) <= 300),
  url               text not null default './',
  send_at           timestamptz not null default now(),
  status            text not null default 'scheduled'
                    check (status in ('scheduled','sending','done','cancelled')),
  dedupe_key        text,
  debug_fail_first  boolean not null default false,
  created_at        timestamptz not null default now(),
  cancelled_at      timestamptz,
  done_at           timestamptz
);
create index if not exists tabi_notifications_due_idx on public.tabi_notifications(send_at) where status = 'scheduled';
create index if not exists tabi_notifications_user_idx on public.tabi_notifications(user_id, created_at desc);
-- 同じ名前(dedupe_key)の「生きている」通知は1件だけ ＝ 二重予約の防止
create unique index if not exists tabi_notifications_live_key_uniq
  on public.tabi_notifications(user_id, dedupe_key)
  where dedupe_key is not null and status in ('scheduled','sending');

-- ---------------------------------------------------------------------
-- 3. 端末ごとの送信記録
--   status: pending=送信待ち / sending=送信中 / accepted=プッシュサービスが受付
--           retry=再試行待ち / failed=失敗(再試行しない) / gone=端末の登録が無効
--           cancelled=取り消し
--   ※ accepted は「配達業者が預かった」段階。端末に届いたかは received_at で判断する
-- ---------------------------------------------------------------------
create table if not exists public.tabi_notification_deliveries (
  id                 uuid primary key default gen_random_uuid(),
  notification_id    uuid not null references public.tabi_notifications(id) on delete cascade,
  subscription_id    uuid not null references public.tabi_push_subscriptions(id) on delete cascade,
  user_id            uuid not null references auth.users(id) on delete cascade,
  status             text not null default 'pending'
                     check (status in ('pending','sending','accepted','retry','failed','gone','cancelled')),
  attempts           int not null default 0,
  next_attempt_at    timestamptz not null default now(),
  sending_started_at timestamptz,
  http_status        int,
  last_error         text,
  receipt_token      uuid not null default gen_random_uuid(),
  accepted_at        timestamptz,
  received_at        timestamptz,
  clicked_at         timestamptz,
  created_at         timestamptz not null default now(),
  -- 1つの通知を同じ端末へ二重に作らない（重複送信の防止）
  unique (notification_id, subscription_id)
);
create index if not exists tabi_deliveries_due_idx
  on public.tabi_notification_deliveries(next_attempt_at) where status in ('pending','retry','sending');
create index if not exists tabi_deliveries_user_idx on public.tabi_notification_deliveries(user_id);

-- ---------------------------------------------------------------------
-- 4. RLS（本人のデータだけ）
-- ---------------------------------------------------------------------
alter table public.tabi_push_subscriptions      enable row level security;
alter table public.tabi_notifications           enable row level security;
alter table public.tabi_notification_deliveries enable row level security;

drop policy if exists "own subs select" on public.tabi_push_subscriptions;
drop policy if exists "own subs update" on public.tabi_push_subscriptions;
drop policy if exists "own subs delete" on public.tabi_push_subscriptions;
create policy "own subs select" on public.tabi_push_subscriptions
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own subs update" on public.tabi_push_subscriptions
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own subs delete" on public.tabi_push_subscriptions
  for delete to authenticated using (user_id = (select auth.uid()));
-- 端末の新規登録は下の register_push_subscription 関数経由のみ

drop policy if exists "own notif select" on public.tabi_notifications;
drop policy if exists "own notif insert" on public.tabi_notifications;
drop policy if exists "own notif update" on public.tabi_notifications;
drop policy if exists "own notif delete" on public.tabi_notifications;
create policy "own notif select" on public.tabi_notifications
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own notif insert" on public.tabi_notifications
  for insert to authenticated with check (user_id = (select auth.uid()) and status = 'scheduled');
create policy "own notif update" on public.tabi_notifications
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own notif delete" on public.tabi_notifications
  for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own deliveries select" on public.tabi_notification_deliveries;
create policy "own deliveries select" on public.tabi_notification_deliveries
  for select to authenticated using (user_id = (select auth.uid()));
-- 送信記録の書き込みはサーバー側（service_role）だけ

-- 利用者に許す操作を最小限にする
revoke all on public.tabi_push_subscriptions, public.tabi_notifications, public.tabi_notification_deliveries from anon;
revoke insert, update, delete on public.tabi_notification_deliveries from authenticated;
revoke insert on public.tabi_push_subscriptions from authenticated;
grant select, update, delete on public.tabi_push_subscriptions to authenticated;
grant select, insert, update, delete on public.tabi_notifications to authenticated;
grant select on public.tabi_notification_deliveries to authenticated;

-- ---------------------------------------------------------------------
-- 端末の登録（同じ端末で別アカウントにログインし直した場合も持ち主を付け替える）
-- ---------------------------------------------------------------------
create or replace function public.tabi_register_push_subscription(
  p_endpoint text, p_p256dh text, p_auth text, p_device_label text, p_user_agent text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if p_endpoint !~ '^https://' then raise exception '端末の登録情報が正しくありません'; end if;
  insert into public.tabi_push_subscriptions(user_id, endpoint, p256dh, auth, device_label, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_device_label, 60), left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        device_label = excluded.device_label, user_agent = excluded.user_agent,
        is_active = true, failure_count = 0, updated_at = now()
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.tabi_register_push_subscription(text,text,text,text,text) from public, anon;
grant execute on function public.tabi_register_push_subscription(text,text,text,text,text) to authenticated;

-- ---------------------------------------------------------------------
-- 予約（予定変更時は同じ dedupe_key の古い予約を自動で取り消してから作る）
-- ---------------------------------------------------------------------
create or replace function public.tabi_schedule_notification(
  p_title text, p_body text, p_send_at timestamptz, p_dedupe_key text default null,
  p_url text default './', p_debug_fail_first boolean default false
) returns uuid
language plpgsql security invoker set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if p_dedupe_key is not null then
    update public.tabi_notifications
       set status = 'cancelled', cancelled_at = now()
     where user_id = auth.uid() and dedupe_key = p_dedupe_key and status = 'scheduled';
  end if;
  insert into public.tabi_notifications(user_id, title, body, url, send_at, dedupe_key, debug_fail_first)
  values (auth.uid(), p_title, coalesce(p_body,''), coalesce(p_url,'./'), p_send_at, p_dedupe_key, p_debug_fail_first)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.tabi_schedule_notification(text,text,timestamptz,text,text,boolean) from public, anon;
grant execute on function public.tabi_schedule_notification(text,text,timestamptz,text,text,boolean) to authenticated;

-- 取り消し（まだ送っていない分だけ止める）
create or replace function public.tabi_cancel_notification(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.tabi_notifications set status = 'cancelled', cancelled_at = now()
   where id = p_id and user_id = auth.uid() and status in ('scheduled','sending');
  update public.tabi_notification_deliveries set status = 'cancelled'
   where notification_id = p_id and user_id = auth.uid() and status in ('pending','retry');
end $$;
revoke all on function public.tabi_cancel_notification(uuid) from public, anon;
grant execute on function public.tabi_cancel_notification(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- サーバー専用の設定（利用者からは見えない場所）
-- ---------------------------------------------------------------------
create schema if not exists tabi_private;
revoke all on schema tabi_private from public, anon, authenticated;
create table if not exists tabi_private.settings (key text primary key, value text not null);
insert into tabi_private.settings(key, value)
values ('cron_secret', encode(gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

create or replace function public.tabi_check_cron_secret(p_secret text) returns boolean
language sql security definer set search_path = public, tabi_private as $$
  select exists (select 1 from tabi_private.settings where key = 'cron_secret' and value = p_secret);
$$;
revoke all on function public.tabi_check_cron_secret(text) from public, anon, authenticated;
grant execute on function public.tabi_check_cron_secret(text) to service_role;

-- ---------------------------------------------------------------------
-- 送る分を「予約」する（同時に2回動いても同じ記録を二重に取らない）
-- ---------------------------------------------------------------------
create or replace function public.tabi_claim_due_deliveries(p_limit int default 50, p_notification uuid default null)
returns table (
  delivery_id uuid, receipt_token uuid, attempts int,
  notification_id uuid, title text, body text, url text, debug_fail_first boolean,
  subscription_id uuid, endpoint text, p256dh text, auth text
)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  -- (1) 時刻になった予約を「送信中」にし、その人の有効な端末ぶんの送信記録を作る
  with due as (
    update public.tabi_notifications n set status = 'sending'
     where n.status = 'scheduled' and n.send_at <= now()
       and (p_notification is null or n.id = p_notification)
    returning n.id, n.user_id
  )
  insert into public.tabi_notification_deliveries(notification_id, subscription_id, user_id)
  select due.id, s.id, due.user_id
    from due join public.tabi_push_subscriptions s on s.user_id = due.user_id and s.is_active
  on conflict (notification_id, subscription_id) do nothing;

  -- (2) 送信待ち・再試行待ち・途中で止まった分（5分以上）を取り出し、送信中にする
  return query
  with picked as (
    select d.id
      from public.tabi_notification_deliveries d
      join public.tabi_notifications n on n.id = d.notification_id
     where n.status <> 'cancelled'
       and (p_notification is null or d.notification_id = p_notification)
       and (
            (d.status in ('pending','retry') and d.next_attempt_at <= now())
         or (d.status = 'sending' and d.sending_started_at < now() - interval '5 minutes')
       )
     order by d.next_attempt_at
     limit p_limit
     for update of d skip locked
  ), upd as (
    update public.tabi_notification_deliveries d
       set status = 'sending', sending_started_at = now(), attempts = d.attempts + 1
      from picked where d.id = picked.id
    returning d.*
  )
  select upd.id, upd.receipt_token, upd.attempts,
         n.id, n.title, n.body, n.url, n.debug_fail_first,
         s.id, s.endpoint, s.p256dh, s.auth
    from upd
    join public.tabi_notifications n on n.id = upd.notification_id
    join public.tabi_push_subscriptions s on s.id = upd.subscription_id;
end $$;
revoke all on function public.tabi_claim_due_deliveries(int, uuid) from public, anon, authenticated;
grant execute on function public.tabi_claim_due_deliveries(int, uuid) to service_role;

-- 全端末の処理が終わった通知を「完了」にする
create or replace function public.tabi_finish_notifications() returns void
language sql security definer set search_path = public as $$
  update public.tabi_notifications n set status = 'done', done_at = now()
   where n.status = 'sending'
     and not exists (select 1 from public.tabi_notification_deliveries d
                      where d.notification_id = n.id and d.status in ('pending','retry','sending'));
$$;
revoke all on function public.tabi_finish_notifications() from public, anon, authenticated;
grant execute on function public.tabi_finish_notifications() to service_role;

-- 端末ごとの連続失敗回数を数える
create or replace function public.tabi_increment_failure(p_subscription uuid) returns void
language sql security definer set search_path = public as $$
  update public.tabi_push_subscriptions set failure_count = failure_count + 1 where id = p_subscription;
$$;
revoke all on function public.tabi_increment_failure(uuid) from public, anon, authenticated;
grant execute on function public.tabi_increment_failure(uuid) to service_role;

-- 端末からの「受信した」「タップした」報告（合言葉 receipt_token が一致したときだけ）
create or replace function public.tabi_record_receipt(p_delivery uuid, p_token uuid, p_kind text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  if p_kind = 'received' then
    update public.tabi_notification_deliveries set received_at = coalesce(received_at, now())
     where id = p_delivery and receipt_token = p_token;
  elsif p_kind = 'clicked' then
    update public.tabi_notification_deliveries
       set clicked_at = coalesce(clicked_at, now()), received_at = coalesce(received_at, now())
     where id = p_delivery and receipt_token = p_token;
  else
    return false;
  end if;
  get diagnostics v_count = row_count;
  return v_count > 0;
end $$;
revoke all on function public.tabi_record_receipt(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.tabi_record_receipt(uuid, uuid, text) to service_role;

-- ---------------------------------------------------------------------
-- 5. Cron（毎分、予約時刻になった通知と再試行分を送る）
--   pg_cron … データベースの中の目覚まし時計
--   pg_net  … データベースから送信プログラム(tabi-push)を呼び出す道具
-- ---------------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;

insert into tabi_private.settings(key, value)
values ('function_url', 'https://hortngwcijhjagwmcoxo.supabase.co/functions/v1/tabi-push')
on conflict (key) do update set value = excluded.value;

create or replace function tabi_private.call_dispatch() returns void
language plpgsql security definer set search_path = tabi_private, public as $$
declare v_url text; v_secret text;
begin
  -- 送る予定がないときは呼び出さない（無料枠の節約）
  if not exists (select 1 from public.tabi_notifications where status = 'scheduled' and send_at <= now())
     and not exists (select 1 from public.tabi_notification_deliveries
                      where status in ('pending','retry','sending') and next_attempt_at <= now()) then
    return;
  end if;
  select value into v_url from tabi_private.settings where key = 'function_url';
  select value into v_secret from tabi_private.settings where key = 'cron_secret';
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', v_secret),
    body := jsonb_build_object('action','dispatch'),
    timeout_milliseconds := 30000
  );
end $$;
revoke all on function tabi_private.call_dispatch() from public, anon, authenticated;

-- 同じ名前のジョブがあれば置き換え（二重登録の防止）
select cron.unschedule(jobid) from cron.job where jobname = 'tabi-push-dispatch';
select cron.schedule('tabi-push-dispatch', '* * * * *', 'select tabi_private.call_dispatch()');

-- 古い送信記録の掃除（30日より前の検証データを毎日4時(日本時間)に削除）
select cron.unschedule(jobid) from cron.job where jobname = 'tabi-push-cleanup';
select cron.schedule('tabi-push-cleanup', '0 19 * * *',
  $c$delete from public.tabi_notifications where created_at < now() - interval '30 days'$c$);

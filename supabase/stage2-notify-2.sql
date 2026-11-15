-- =====================================================================
-- 旅ベース 第2段階前半 E・F：送信状況の表示と、旅程変更の通知
-- （stage2-notify.sql を実行済みの drops で、SQL Editor に全文を貼って Run）
-- 何度実行しても壊れないように書いてあります。表は増やさず、関数と自動処理を足すだけです。
--
-- 変わること
--   E. 旅の参加者が、その旅の通知の送信状況（誰の・どの端末に・受付済／受信確認済／失敗）を見られる関数
--      ・見られるのはその旅の参加者だけ。端末の宛先URLや鍵は返さない
--   F. 移動・予定が変わったら、変えた人以外の参加者に「旅程が変更されました」を5分後に送る
--      ・5分の間の変更は1回にまとめる。通知設定の「旅程変更」がオフなら送らない
-- =====================================================================

-- ---------------------------------------------------------------------
-- E. 送信状況（新しい順に最大50件）
-- ---------------------------------------------------------------------
create or replace function public.tabi_trip_delivery_status(p_trip uuid)
returns table (
  send_at timestamptz, title text, kind text, display_name text, device_label text,
  status text, accepted_at timestamptz, received_at timestamptz, clicked_at timestamptz,
  attempts int, notification_status text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.tabi_is_member(p_trip) then raise exception 'この旅の参加者ではありません'; end if;
  return query
  select n.send_at, n.title, n.kind,
         coalesce(m.display_name, '（参加していない人）'),
         coalesce(nullif(s.device_label, ''), '端末'),
         d.status, d.accepted_at, d.received_at, d.clicked_at, d.attempts, n.status
    from public.tabi_notifications n
    join public.tabi_notification_deliveries d on d.notification_id = n.id
    join public.tabi_push_subscriptions s on s.id = d.subscription_id
    left join public.tabi_members m on m.trip_id = n.trip_id and m.user_id = n.user_id
   where n.trip_id = p_trip
   order by n.send_at desc, m.display_name, s.device_label
   limit 50;
end $$;
revoke all on function public.tabi_trip_delivery_status(uuid) from public, anon;
grant execute on function public.tabi_trip_delivery_status(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- F. 旅程変更の通知
--   ・変えた人（ログイン中の人）には送らない
--   ・まだ送っていない「旅程変更」があれば新しく作らない（＝5分の間の変更をまとめる）
--   ・有効期限は6時間（それより遅れて届くなら送らない）
--   ・旅が終わった後（終了日の翌日以降）の変更では送らない
-- ---------------------------------------------------------------------
create or replace function tabi_private.on_itinerary_change() returns trigger
language plpgsql security definer set search_path = public, tabi_private as $$
declare
  v_trip uuid := coalesce(new.trip_id, old.trip_id);
  t public.tabi_trips; r record;
begin
  if auth.uid() is null then return null; end if; -- 自動処理（定期削除など）による変更では送らない
  select * into t from public.tabi_trips where id = v_trip;
  if not found or t.deleted_at is not null then return null; end if;
  if t.end_date < (now() at time zone t.timezone)::date then return null; end if;
  select * into r from tabi_private.rule(v_trip, 'change', 5);
  if not r.enabled then return null; end if;
  insert into public.tabi_notifications(user_id, trip_id, kind, title, body, url, send_at, expires_at, urgency, dedupe_key)
  select m.user_id, v_trip, 'change',
         left('📝 「' || t.name || '」の旅程が変わりました', 100),
         '開いて最新の旅程を確認してください。',
         './#/trip/' || v_trip,
         now() + interval '5 minutes', now() + interval '6 hours', 'normal',
         'trip:' || v_trip || ':change'
    from public.tabi_members m
   where m.trip_id = v_trip and m.user_id <> auth.uid()
  on conflict (user_id, dedupe_key) where dedupe_key is not null and status in ('scheduled','sending') do nothing;
  return null;
end $$;

drop trigger if exists tabi_notify_change_segments on public.tabi_segments;
create trigger tabi_notify_change_segments after insert or update or delete on public.tabi_segments
  for each row execute function tabi_private.on_itinerary_change();
drop trigger if exists tabi_notify_change_events on public.tabi_events;
create trigger tabi_notify_change_events after insert or update or delete on public.tabi_events
  for each row execute function tabi_private.on_itinerary_change();

-- 「旅程変更」をオフにしたら、まだ送っていない旅程変更の通知も取り消す
create or replace function tabi_private.on_change_rule() returns trigger
language plpgsql security definer set search_path = public, tabi_private as $$
begin
  if new.kind = 'change' and not new.enabled then
    delete from public.tabi_notifications
     where trip_id = new.trip_id and kind = 'change' and status = 'scheduled';
  end if;
  return null;
end $$;
drop trigger if exists tabi_notify_change_rule on public.tabi_notification_rules;
create trigger tabi_notify_change_rule after insert or update on public.tabi_notification_rules
  for each row execute function tabi_private.on_change_rule();

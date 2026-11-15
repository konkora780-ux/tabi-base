-- =====================================================================
-- 旅ベース 第2段階前半 A：旅程から通知の送信予定を自動で作る
-- （setup.sql と stage1-db.sql を実行済みの drops で、SQL Editor に全文を貼って Run）
-- 何度実行しても壊れないように書いてあります。既存の表は消さず、列と関数を足すだけです。
--
-- 変わること
--   1. tabi_notifications（送る予定の通知）に「どの旅・どの移動の通知か」「有効期限」などの列を足す
--   2. tabi_notification_rules（旅ごとの通知ルール：何分前・オンオフ）を新しく作る
--   3. 移動・旅・参加者・ルールが変わるたびに、その旅の送信予定を作り直す自動処理
--      （運休・削除・外された人の分は取り消す）
--   4. 送る直前の確認（期限切れ・旅程が変わった・参加していない → 送らない）
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 送信予定の列を足す
-- ---------------------------------------------------------------------
alter table public.tabi_notifications
  add column if not exists trip_id        uuid references public.tabi_trips(id) on delete cascade,
  add column if not exists kind           text,          -- day_before / prep / depart / arrive / change（null はテスト通知）
  add column if not exists target_type    text,          -- segment など
  add column if not exists target_id      uuid,
  add column if not exists target_version int,           -- 作ったときの移動の版番号（送る直前に読み直して比べる）
  add column if not exists expires_at     timestamptz,   -- これを過ぎたら送らない
  add column if not exists urgency        text not null default 'normal';

alter table public.tabi_notifications drop constraint if exists tabi_notifications_status_check;
alter table public.tabi_notifications add constraint tabi_notifications_status_check
  check (status in ('scheduled','sending','done','cancelled','expired'));
alter table public.tabi_notifications drop constraint if exists tabi_notifications_urgency_check;
alter table public.tabi_notifications add constraint tabi_notifications_urgency_check
  check (urgency in ('normal','high'));
create index if not exists tabi_notifications_trip_idx on public.tabi_notifications(trip_id) where trip_id is not null;

alter table public.tabi_notification_deliveries drop constraint if exists tabi_notification_deliveries_status_check;
alter table public.tabi_notification_deliveries add constraint tabi_notification_deliveries_status_check
  check (status in ('pending','sending','accepted','retry','failed','gone','cancelled','expired'));

-- 利用者が自分で作れるのはテスト通知だけ（旅の通知は自動処理だけが作る）
drop policy if exists "own notif insert" on public.tabi_notifications;
create policy "own notif insert" on public.tabi_notifications
  for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'scheduled' and trip_id is null and kind is null);
drop policy if exists "own notif update" on public.tabi_notifications;
create policy "own notif update" on public.tabi_notifications
  for update to authenticated using (user_id = (select auth.uid()) and trip_id is null)
  with check (user_id = (select auth.uid()) and trip_id is null);

-- ---------------------------------------------------------------------
-- 2. 通知ルール（旅ごと。行がない種類は初期値を使う）
--   day_before: minutes = 前日の何時何分か（0時からの分。初期値 1200 = 20:00）
--   prep / depart / arrive: minutes = 何分前か（初期値 90 / 30 / 10）
-- ---------------------------------------------------------------------
create table if not exists public.tabi_notification_rules (
  trip_id     uuid not null references public.tabi_trips(id) on delete cascade,
  kind        text not null check (kind in ('day_before','prep','depart','arrive','change')),
  minutes     int  check (minutes between 0 and 1439),
  enabled     boolean not null default true,
  updated_at  timestamptz not null default now(),
  primary key (trip_id, kind)
);
alter table public.tabi_notification_rules enable row level security;
drop policy if exists "rules select" on public.tabi_notification_rules;
drop policy if exists "rules write" on public.tabi_notification_rules;
create policy "rules select" on public.tabi_notification_rules for select to authenticated
  using (public.tabi_is_member(trip_id));
create policy "rules write" on public.tabi_notification_rules for all to authenticated
  using (public.tabi_can_edit(trip_id)) with check (public.tabi_can_edit(trip_id));
revoke all on public.tabi_notification_rules from anon, authenticated;
grant select, insert, update, delete on public.tabi_notification_rules to authenticated;

create or replace function tabi_private.rule(p_trip uuid, p_kind text, p_default int, out minutes int, out enabled boolean)
language sql stable security definer set search_path = public as $$
  select coalesce((select r.minutes from public.tabi_notification_rules r where r.trip_id = p_trip and r.kind = p_kind), p_default),
         coalesce((select r.enabled from public.tabi_notification_rules r where r.trip_id = p_trip and r.kind = p_kind), true);
$$;

create or replace function tabi_private.mode_label(p_mode text) returns text
language sql immutable as $$
  select case p_mode
    when 'flight' then '✈️' when 'shinkansen' then '🚄' when 'local_train' then '🚃' when 'sleeper_train' then '🛏️'
    when 'highway_bus' then '🚌' when 'route_bus' then '🚌' when 'taxi' then '🚕' when 'rental_car' then '🚗'
    when 'own_car' then '🚗' when 'ferry' then '⛴️' when 'ropeway' then '🚡' when 'walk_bike' then '🚶' else '📍' end;
$$;

-- ---------------------------------------------------------------------
-- 3. その旅の送信予定を作り直す
--   ・まだ送っていない予定（scheduled）を全部取り消してから、今の旅程・参加者・ルールで作る
--   ・すでに送った（送信中・完了）同じ通知は作り直さない（二重送信の防止）
--   ・有効期限を過ぎたものは作らない
--   ・本文に予約番号は入れない
-- ---------------------------------------------------------------------
create or replace function tabi_private.rebuild_trip_notifications(p_trip uuid) returns void
language plpgsql security definer set search_path = public, tabi_private as $$
declare
  t public.tabi_trips; r_day record; r_prep record; r_dep record; r_arr record;
begin
  -- 取り消し：まだ送っていない旅の通知（旅程変更の通知は除く）は消して作り直す
  -- （まだ1度も送っていないので、記録として残す必要がない。残すと編集のたびに行が増えるため）
  delete from public.tabi_notifications
   where trip_id = p_trip and status = 'scheduled' and kind in ('day_before','prep','depart','arrive');
  -- 外された人の分は、送信中・再試行待ちの配信も止める
  update public.tabi_notification_deliveries d set status = 'cancelled'
    from public.tabi_notifications n
   where n.id = d.notification_id and n.trip_id = p_trip and d.status in ('pending','retry')
     and (n.status = 'cancelled'
          or not exists (select 1 from public.tabi_members m where m.trip_id = p_trip and m.user_id = n.user_id));

  select * into t from public.tabi_trips where id = p_trip;
  if not found or t.deleted_at is not null then return; end if;

  select * into r_day  from tabi_private.rule(p_trip, 'day_before', 1200);
  select * into r_prep from tabi_private.rule(p_trip, 'prep', 90);
  select * into r_dep  from tabi_private.rule(p_trip, 'depart', 30);
  select * into r_arr  from tabi_private.rule(p_trip, 'arrive', 10);

  with items as (
    -- 前日夜（旅に1つ。期限は前日23:00、ただし送る時刻より前なら送る時刻＋1時間）
    select 'day_before'::text as kind, null::text as target_type, null::uuid as target_id, null::int as target_version,
           ((t.start_date - 1) + make_interval(mins => r_day.minutes)) at time zone t.timezone as send_at,
           greatest(((t.start_date - 1) + time '23:00') at time zone t.timezone,
                    ((t.start_date - 1) + make_interval(mins => r_day.minutes)) at time zone t.timezone + interval '1 hour') as expires_at,
           'normal'::text as urgency,
           '🧳 明日から「' || t.name || '」' as title,
           '旅程を確認して、持ち物や出発時刻を見直しておきましょう。' as body,
           'day_before:' || t.id as key
     where r_day.enabled
    union all
    -- 出発準備（その日の最初の移動）
    select 'prep', 'segment', s.id, s.version,
           s.depart_at - make_interval(mins => r_prep.minutes),
           greatest(s.depart_at - interval '30 minutes', s.depart_at - make_interval(mins => r_prep.minutes) + interval '10 minutes'),
           'normal',
           '⏰ そろそろ出発の準備を',
           coalesce(nullif(s.service_name, ''), '移動') || ' ' || to_char(s.depart_at at time zone s.depart_tz, 'HH24:MI') || '発'
             || coalesce('（' || nullif(s.from_name, '') || '）', ''),
           'prep:' || s.id
      from (select distinct on ((x.depart_at at time zone x.depart_tz)::date) x.*
              from public.tabi_segments x
             where x.trip_id = p_trip and x.deleted_at is null and x.status = 'scheduled' and x.depart_at is not null
             order by (x.depart_at at time zone x.depart_tz)::date, x.depart_at) s
     where r_prep.enabled
    union all
    -- 出発前（各移動）
    select 'depart', 'segment', s.id, s.version,
           s.depart_at - make_interval(mins => r_dep.minutes), s.depart_at, 'high',
           tabi_private.mode_label(s.mode) || ' ' || r_dep.minutes || '分後に出発：' || coalesce(nullif(s.service_name, ''), '移動'),
           to_char(s.depart_at at time zone s.depart_tz, 'HH24:MI') || '発'
             || coalesce(' ' || nullif(s.from_name, ''), '')
             || case when s.platform ~ '^\d+$' then ' ' || s.platform || '番線' else coalesce(' ' || nullif(s.platform, ''), '') end
             || case when s.car_no ~ '^\d+$' then ' ' || s.car_no || '号車' else coalesce(' ' || nullif(s.car_no, ''), '') end
             || coalesce(' ' || nullif(s.seat, ''), '')
             || coalesce(' → ' || nullif(s.to_name, ''), ''),
           'depart:' || s.id
      from public.tabi_segments s
     where r_dep.enabled and s.trip_id = p_trip and s.deleted_at is null and s.status = 'scheduled' and s.depart_at is not null
    union all
    -- 到着予定（各移動。「予定では」と入れる）
    select 'arrive', 'segment', s.id, s.version,
           s.arrive_at - make_interval(mins => r_arr.minutes), s.arrive_at, 'high',
           tabi_private.mode_label(s.mode) || ' まもなく到着：' || coalesce(nullif(s.to_name, ''), '目的地'),
           '予定では ' || to_char(s.arrive_at at time zone s.arrive_tz, 'HH24:MI') || ' に到着します。降りる準備をしましょう。',
           'arrive:' || s.id
      from public.tabi_segments s
     where r_arr.enabled and s.trip_id = p_trip and s.deleted_at is null and s.status = 'scheduled' and s.arrive_at is not null
  )
  insert into public.tabi_notifications(user_id, trip_id, kind, target_type, target_id, target_version,
                                        title, body, url, send_at, expires_at, urgency, dedupe_key)
  select m.user_id, p_trip, i.kind, i.target_type, i.target_id, i.target_version,
         left(i.title, 100), left(i.body, 300), './#/trip/' || p_trip, i.send_at, i.expires_at, i.urgency,
         'trip:' || p_trip || ':' || i.key
    from items i cross join public.tabi_members m
   where m.trip_id = p_trip
     and i.expires_at > now()
     -- 同じ時刻の同じ通知をすでに送った（送信中・完了）なら作らない
     and not exists (select 1 from public.tabi_notifications o
                      where o.user_id = m.user_id and o.dedupe_key = 'trip:' || p_trip || ':' || i.key
                        and o.send_at = i.send_at and o.status in ('sending','done'))
  on conflict (user_id, dedupe_key) where dedupe_key is not null and status in ('scheduled','sending') do nothing;
end $$;
revoke all on function tabi_private.rebuild_trip_notifications(uuid) from public, anon, authenticated;

-- 変更があったら作り直す（移動・旅・参加者・ルール）
create or replace function tabi_private.on_trip_change() returns trigger
language plpgsql security definer set search_path = public, tabi_private as $$
begin
  if tg_table_name = 'tabi_trips' then
    perform tabi_private.rebuild_trip_notifications(coalesce(new.id, old.id));
  else
    perform tabi_private.rebuild_trip_notifications(coalesce(new.trip_id, old.trip_id));
  end if;
  return null;
end $$;

drop trigger if exists tabi_notify_segments on public.tabi_segments;
create trigger tabi_notify_segments after insert or update or delete on public.tabi_segments
  for each row execute function tabi_private.on_trip_change();
drop trigger if exists tabi_notify_trips on public.tabi_trips;
create trigger tabi_notify_trips after update of name, start_date, timezone, deleted_at on public.tabi_trips
  for each row execute function tabi_private.on_trip_change();
drop trigger if exists tabi_notify_members on public.tabi_members;
create trigger tabi_notify_members after insert or delete on public.tabi_members
  for each row execute function tabi_private.on_trip_change();
drop trigger if exists tabi_notify_rules on public.tabi_notification_rules;
create trigger tabi_notify_rules after insert or update or delete on public.tabi_notification_rules
  for each row execute function tabi_private.on_trip_change();

-- ---------------------------------------------------------------------
-- 4. 送る分を取り出す（送る直前の確認つき）
--   ・有効期限を過ぎた → 期限切れ（送らない）
--   ・移動の版番号が変わった／運休／削除／旅が削除／参加していない → 取消（送らない）
--   戻り値に有効期限・緊急度を足したため、いったん削除して作り直す
-- ---------------------------------------------------------------------
drop function if exists public.tabi_claim_due_deliveries(int, uuid);
create or replace function public.tabi_claim_due_deliveries(p_limit int default 50, p_notification uuid default null)
returns table (
  delivery_id uuid, receipt_token uuid, attempts int,
  notification_id uuid, title text, body text, url text, debug_fail_first boolean,
  subscription_id uuid, endpoint text, p256dh text, auth text,
  expires_at timestamptz, urgency text, trip_id uuid, kind text
)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  -- (0) 送る直前の確認
  update public.tabi_notifications n set status = 'expired'
   where n.expires_at is not null and n.expires_at <= now()
     and (n.status = 'scheduled'
          or (n.status = 'sending' and exists (select 1 from public.tabi_notification_deliveries x
                where x.notification_id = n.id and x.status in ('pending','retry','sending'))));
  update public.tabi_notification_deliveries d set status = 'expired'
    from public.tabi_notifications n
   where n.id = d.notification_id and n.status = 'expired' and d.status in ('pending','retry','sending');
  update public.tabi_notifications n set status = 'cancelled', cancelled_at = now()
   where n.status = 'scheduled' and n.send_at <= now() and n.trip_id is not null
     and (not exists (select 1 from public.tabi_trips t where t.id = n.trip_id and t.deleted_at is null)
          or not exists (select 1 from public.tabi_members m where m.trip_id = n.trip_id and m.user_id = n.user_id)
          or (n.target_type = 'segment' and not exists (
                select 1 from public.tabi_segments s
                 where s.id = n.target_id and s.version = n.target_version
                   and s.status = 'scheduled' and s.deleted_at is null)));

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
     where n.status not in ('cancelled','expired')
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
         s.id, s.endpoint, s.p256dh, s.auth,
         n.expires_at, n.urgency, n.trip_id, n.kind
    from upd
    join public.tabi_notifications n on n.id = upd.notification_id
    join public.tabi_push_subscriptions s on s.id = upd.subscription_id;
end $$;
revoke all on function public.tabi_claim_due_deliveries(int, uuid) from public, anon, authenticated;
grant execute on function public.tabi_claim_due_deliveries(int, uuid) to service_role;

-- 完了：期限切れ・取消になった配信も「終わった」として数える
create or replace function public.tabi_finish_notifications() returns void
language sql security definer set search_path = public as $$
  update public.tabi_notifications n set status = 'done', done_at = now()
   where n.status = 'sending'
     and not exists (select 1 from public.tabi_notification_deliveries d
                      where d.notification_id = n.id and d.status in ('pending','retry','sending'));
$$;
revoke all on function public.tabi_finish_notifications() from public, anon, authenticated;
grant execute on function public.tabi_finish_notifications() to service_role;

-- ---------------------------------------------------------------------
-- 5. 今ある旅の送信予定を一度作る
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select id from public.tabi_trips where deleted_at is null loop
    perform tabi_private.rebuild_trip_notifications(r.id);
  end loop;
end $$;

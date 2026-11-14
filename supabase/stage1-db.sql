-- =====================================================================
-- 旅ベース 第1段階前半① データベースとRLS（詳細設計書 第3版 第4・6章）
-- Supabase の「SQL Editor」に全文を貼り付けて「Run」で実行します。
-- 何度実行しても壊れないように書いてあります。
-- 既存の drops の表には触れません（すべて tabi_ で始まる名前）。
--
-- 作るもの
--   表     : tabi_trips / tabi_members / tabi_trip_invitations / tabi_places /
--            tabi_segments / tabi_events / tabi_trip_secrets /
--            tabi_change_history / tabi_trip_participants
--   決まり : RLS（参加していない人は見られない・閲覧者は編集できない 等）
--   関数   : 招待リンクの作成・参加・無効化、作成者の交代
--   定期処理: 毎日 午前3時（日本時間）の削除
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. 表
-- ---------------------------------------------------------------------

-- 旅
create table if not exists public.tabi_trips (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null default auth.uid() references auth.users(id),
  name          text not null check (char_length(name) between 1 and 100),
  start_date    date not null,
  end_date      date not null,
  timezone      text not null default 'Asia/Tokyo',
  destination   text check (char_length(destination) <= 200),
  memo          text check (char_length(memo) <= 2000),
  -- 予約番号を見られる範囲: editors=作成者・編集者のみ（初期値）／ all=全参加者
  secret_scope  text not null default 'editors' check (secret_scope in ('editors','all')),
  version       int not null default 1,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  check (end_date >= start_date)
);

-- 参加者と権限
create table if not exists public.tabi_members (
  trip_id       uuid not null references public.tabi_trips(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  role          text not null check (role in ('owner','editor','viewer')),
  display_name  text not null default '' check (char_length(display_name) <= 40),
  joined_at     timestamptz not null default now(),
  primary key (trip_id, user_id)
);
create index if not exists tabi_members_user_idx on public.tabi_members(user_id);
-- 作成者は旅に1人だけ
create unique index if not exists tabi_members_one_owner on public.tabi_members(trip_id) where role = 'owner';

-- 招待リンク（秘密コードそのものは保存せず、ハッシュ値だけ）
create table if not exists public.tabi_trip_invitations (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.tabi_trips(id) on delete cascade,
  code_hash   text not null unique,
  role        text not null check (role in ('editor','viewer')),
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  used_at     timestamptz,
  used_by     uuid references auth.users(id),
  revoked_at  timestamptz
);
create index if not exists tabi_invitations_trip_idx on public.tabi_trip_invitations(trip_id);

-- 地点
create table if not exists public.tabi_places (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.tabi_trips(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 100),
  kind        text check (char_length(kind) <= 30),
  lat         double precision check (lat between -90 and 90),
  lng         double precision check (lng between -180 and 180),
  address     text check (char_length(address) <= 300),
  timezone    text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists tabi_places_trip_idx on public.tabi_places(trip_id);

-- 移動（13種類）
create table if not exists public.tabi_segments (
  id             uuid primary key default gen_random_uuid(),
  trip_id        uuid not null references public.tabi_trips(id) on delete cascade,
  mode           text not null check (mode in (
                   'flight','shinkansen','local_train','sleeper_train',
                   'highway_bus','route_bus','taxi','rental_car','own_car',
                   'ferry','ropeway','walk_bike','other')),
  carrier        text check (char_length(carrier) <= 100),   -- 会社名
  service_name   text check (char_length(service_name) <= 100), -- 便名・列車名・系統
  from_place_id  uuid references public.tabi_places(id) on delete set null,
  from_name      text check (char_length(from_name) <= 100),
  depart_at      timestamptz,
  depart_tz      text not null default 'Asia/Tokyo',
  to_place_id    uuid references public.tabi_places(id) on delete set null,
  to_name        text check (char_length(to_name) <= 100),
  arrive_at      timestamptz,
  arrive_tz      text not null default 'Asia/Tokyo',
  platform       text check (char_length(platform) <= 50),  -- 乗り場・番線・ゲート
  car_no         text check (char_length(car_no) <= 30),    -- 号車
  seat           text check (char_length(seat) <= 50),
  memo           text check (char_length(memo) <= 2000),
  details        jsonb not null default '{}'::jsonb,        -- 移動手段ごとの追加項目
  status         text not null default 'scheduled' check (status in ('scheduled','cancelled')),
  version        int not null default 1,
  created_by     uuid default auth.uid() references auth.users(id) on delete set null,
  updated_by     uuid default auth.uid() references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  check (arrive_at is null or depart_at is null or arrive_at >= depart_at)
);
create index if not exists tabi_segments_trip_idx on public.tabi_segments(trip_id, depart_at);

-- 予定（観光・食事・宿など）
create table if not exists public.tabi_events (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.tabi_trips(id) on delete cascade,
  category    text not null default 'other'
              check (category in ('sightseeing','meal','stay','shopping','meeting','other')),
  name        text not null check (char_length(name) between 1 and 100),
  place_id    uuid references public.tabi_places(id) on delete set null,
  place_name  text check (char_length(place_name) <= 100),
  start_at    timestamptz,
  end_at      timestamptz,
  timezone    text not null default 'Asia/Tokyo',
  memo        text check (char_length(memo) <= 2000),
  status      text not null default 'scheduled' check (status in ('scheduled','cancelled')),
  version     int not null default 1,
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  updated_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  check (end_at is null or start_at is null or end_at >= start_at)
);
create index if not exists tabi_events_trip_idx on public.tabi_events(trip_id, start_at);

-- 機密情報（予約番号・確認コード）
create table if not exists public.tabi_trip_secrets (
  id           uuid primary key default gen_random_uuid(),
  trip_id      uuid not null references public.tabi_trips(id) on delete cascade,
  target_type  text not null check (target_type in ('trip','segment','event')),
  target_id    uuid not null,
  kind         text not null default 'reservation' check (kind in ('reservation','confirmation','other')),
  label        text check (char_length(label) <= 50),
  value        text not null check (char_length(value) between 1 and 200),
  updated_by   uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at   timestamptz not null default now()
);
create index if not exists tabi_secrets_trip_idx on public.tabi_trip_secrets(trip_id);

-- 変更履歴（画面からは書けない。自動で記録）
create table if not exists public.tabi_change_history (
  id           bigint generated always as identity primary key,
  trip_id      uuid not null references public.tabi_trips(id) on delete cascade,
  table_name   text not null,
  row_id       text not null,
  op           text not null check (op in ('insert','update','delete')),
  before_data  jsonb,
  after_data   jsonb,
  summary      text,
  new_version  int,
  changed_by   uuid,
  changed_at   timestamptz not null default now()
);
create index if not exists tabi_history_trip_idx on public.tabi_change_history(trip_id, changed_at desc);

-- 予定ごとの参加者（別行動用。表だけ先に作る）
create table if not exists public.tabi_trip_participants (
  trip_id      uuid not null,
  target_type  text not null check (target_type in ('segment','event')),
  target_id    uuid not null,
  user_id      uuid not null,
  primary key (target_type, target_id, user_id),
  -- その旅の参加者しか登録できない。退会すると自動で消える
  foreign key (trip_id, user_id) references public.tabi_members(trip_id, user_id) on delete cascade
);
create index if not exists tabi_participants_trip_idx on public.tabi_trip_participants(trip_id);

-- ---------------------------------------------------------------------
-- 2. 権限を調べる関数（RLSの中で使う）
-- ---------------------------------------------------------------------
create or replace function public.tabi_my_role(p_trip uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from public.tabi_members where trip_id = p_trip and user_id = auth.uid();
$$;
create or replace function public.tabi_is_member(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tabi_members where trip_id = p_trip and user_id = auth.uid());
$$;
create or replace function public.tabi_can_edit(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tabi_members
                  where trip_id = p_trip and user_id = auth.uid() and role in ('owner','editor'));
$$;
create or replace function public.tabi_is_owner(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tabi_members
                  where trip_id = p_trip and user_id = auth.uid() and role = 'owner');
$$;
-- 予約番号を見られるか（作成者・編集者は常に可。閲覧者は範囲が「全参加者」のときだけ）
create or replace function public.tabi_can_see_secrets(p_trip uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.tabi_members m join public.tabi_trips t on t.id = m.trip_id
     where m.trip_id = p_trip and m.user_id = auth.uid()
       and (m.role in ('owner','editor') or t.secret_scope = 'all'));
$$;
revoke all on function public.tabi_my_role(uuid), public.tabi_is_member(uuid), public.tabi_can_edit(uuid),
  public.tabi_is_owner(uuid), public.tabi_can_see_secrets(uuid) from public, anon;
grant execute on function public.tabi_my_role(uuid), public.tabi_is_member(uuid), public.tabi_can_edit(uuid),
  public.tabi_is_owner(uuid), public.tabi_can_see_secrets(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. 自動処理（トリガー）
-- ---------------------------------------------------------------------

-- 更新日時・版番号・更新者を自動で入れる（版番号は同時編集の検出に使う）
create or replace function public.tabi_touch() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  if tg_table_name in ('tabi_trips','tabi_segments','tabi_events') then
    new.version := old.version + 1;
  end if;
  if tg_table_name in ('tabi_segments','tabi_events') then
    new.updated_by := coalesce(auth.uid(), new.updated_by);
    new.created_by := old.created_by;
  end if;
  if tg_table_name = 'tabi_trip_secrets' then
    new.updated_by := coalesce(auth.uid(), new.updated_by);
  end if;
  return new;
end $$;

drop trigger if exists tabi_trips_touch on public.tabi_trips;
create trigger tabi_trips_touch before update on public.tabi_trips
  for each row execute function public.tabi_touch();
drop trigger if exists tabi_places_touch on public.tabi_places;
create trigger tabi_places_touch before update on public.tabi_places
  for each row execute function public.tabi_touch();
drop trigger if exists tabi_segments_touch on public.tabi_segments;
create trigger tabi_segments_touch before update on public.tabi_segments
  for each row execute function public.tabi_touch();
drop trigger if exists tabi_events_touch on public.tabi_events;
create trigger tabi_events_touch before update on public.tabi_events
  for each row execute function public.tabi_touch();
drop trigger if exists tabi_secrets_touch on public.tabi_trip_secrets;
create trigger tabi_secrets_touch before update on public.tabi_trip_secrets
  for each row execute function public.tabi_touch();

-- 旅の作成・変更の決まり
create or replace function public.tabi_trips_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('tabi.bypass', true) = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.owner_id := auth.uid(); end if;
    new.version := 1;
    return new;
  end if;
  -- 作成者以外は「予約番号の閲覧範囲」「削除」「作成者」を変えられない
  if auth.uid() is not null and not public.tabi_is_owner(old.id) then
    if new.secret_scope is distinct from old.secret_scope then
      raise exception '予約番号の閲覧範囲を変えられるのは作成者だけです';
    end if;
    if new.deleted_at is distinct from old.deleted_at then
      raise exception '旅を削除できるのは作成者だけです';
    end if;
  end if;
  if auth.uid() is not null and new.owner_id is distinct from old.owner_id then
    raise exception '作成者の変更は「作成者を譲る」から行ってください';
  end if;
  return new;
end $$;
drop trigger if exists tabi_trips_guard on public.tabi_trips;
create trigger tabi_trips_guard before insert or update on public.tabi_trips
  for each row execute function public.tabi_trips_guard();

-- 旅を作った人を、自動で「作成者」として参加者に入れる
create or replace function public.tabi_trips_add_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.tabi_members(trip_id, user_id, role, display_name)
  values (new.id, new.owner_id, 'owner',
          coalesce(split_part(auth.jwt() ->> 'email', '@', 1), ''))
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists tabi_trips_add_owner on public.tabi_trips;
create trigger tabi_trips_add_owner after insert on public.tabi_trips
  for each row execute function public.tabi_trips_add_owner();

-- 参加者の変更の決まり（権限の変更は作成者だけ。自分の表示名は自分で変えられる）
create or replace function public.tabi_members_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or current_setting('tabi.bypass', true) = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' then
    if new.trip_id <> old.trip_id or new.user_id <> old.user_id then
      raise exception '参加者の付け替えはできません';
    end if;
    if new.role is distinct from old.role then
      if not public.tabi_is_owner(old.trip_id) then
        raise exception '権限を変えられるのは作成者だけです';
      end if;
      if old.role = 'owner' or new.role = 'owner' then
        raise exception '作成者の変更は「作成者を譲る」から行ってください';
      end if;
    end if;
    if new.display_name is distinct from old.display_name
       and old.user_id <> auth.uid() and not public.tabi_is_owner(old.trip_id) then
      raise exception 'ほかの人の表示名は変えられません';
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    if old.role = 'owner' then
      raise exception '作成者は退会できません。先に作成者をほかの人に譲ってください';
    end if;
    return old;
  end if;
  return new;
end $$;
drop trigger if exists tabi_members_guard on public.tabi_members;
create trigger tabi_members_guard before update or delete on public.tabi_members
  for each row execute function public.tabi_members_guard();

-- 機密情報の対象が、同じ旅の移動・予定かを確かめる
create or replace function public.tabi_secrets_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.target_type = 'trip' and new.target_id <> new.trip_id then
    raise exception '対象が正しくありません';
  elsif new.target_type = 'segment' and not exists
    (select 1 from public.tabi_segments where id = new.target_id and trip_id = new.trip_id) then
    raise exception '対象の移動がこの旅にありません';
  elsif new.target_type = 'event' and not exists
    (select 1 from public.tabi_events where id = new.target_id and trip_id = new.trip_id) then
    raise exception '対象の予定がこの旅にありません';
  end if;
  if tg_op = 'UPDATE' and new.trip_id <> old.trip_id then
    raise exception '別の旅へは移せません';
  end if;
  return new;
end $$;
drop trigger if exists tabi_secrets_check on public.tabi_trip_secrets;
create trigger tabi_secrets_check before insert or update on public.tabi_trip_secrets
  for each row execute function public.tabi_secrets_check();

-- 移動・予定・地点を別の旅へ移すことは禁止（権限のすり抜け防止）
create or replace function public.tabi_no_trip_move() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.trip_id <> old.trip_id then raise exception '別の旅へは移せません'; end if;
  return new;
end $$;
drop trigger if exists tabi_places_nomove on public.tabi_places;
create trigger tabi_places_nomove before update on public.tabi_places
  for each row execute function public.tabi_no_trip_move();
drop trigger if exists tabi_segments_nomove on public.tabi_segments;
create trigger tabi_segments_nomove before update on public.tabi_segments
  for each row execute function public.tabi_no_trip_move();
drop trigger if exists tabi_events_nomove on public.tabi_events;
create trigger tabi_events_nomove before update on public.tabi_events
  for each row execute function public.tabi_no_trip_move();

-- 変更履歴を自動で記録（機密情報は実際の値を残さない）
create or replace function public.tabi_record_history() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_trip uuid; v_row text; v_before jsonb; v_after jsonb; v_summary text; v_version int;
begin
  if tg_table_name = 'tabi_trips' then
    v_trip := coalesce(new.id, old.id);
  else
    v_trip := coalesce(new.trip_id, old.trip_id);
  end if;
  -- 旅ごと完全削除されるとき（30日後の削除）は記録しない
  if not exists (select 1 from public.tabi_trips where id = v_trip) then
    return null;
  end if;

  if tg_table_name = 'tabi_members' then
    v_row := coalesce(new.user_id, old.user_id)::text;
  else
    v_row := coalesce(new.id, old.id)::text;
  end if;

  if tg_table_name = 'tabi_trip_secrets' then
    v_summary := case tg_op when 'INSERT' then '予約番号などを登録しました'
                            when 'UPDATE' then '予約番号などを変更しました'
                            else '予約番号などを削除しました' end;
    v_before := case when tg_op <> 'INSERT' then jsonb_build_object('target_type', old.target_type, 'target_id', old.target_id, 'kind', old.kind) end;
    v_after  := case when tg_op <> 'DELETE' then jsonb_build_object('target_type', new.target_type, 'target_id', new.target_id, 'kind', new.kind) end;
  else
    v_before := case when tg_op <> 'INSERT' then to_jsonb(old) end;
    v_after  := case when tg_op <> 'DELETE' then to_jsonb(new) end;
    if v_after ? 'version' then v_version := (v_after ->> 'version')::int; end if;
  end if;

  insert into public.tabi_change_history(trip_id, table_name, row_id, op, before_data, after_data, summary, new_version, changed_by)
  values (v_trip, tg_table_name, v_row, lower(tg_op), v_before, v_after, v_summary, v_version, auth.uid());
  return null;
end $$;

drop trigger if exists tabi_trips_history on public.tabi_trips;
create trigger tabi_trips_history after insert or update on public.tabi_trips
  for each row execute function public.tabi_record_history();
drop trigger if exists tabi_members_history on public.tabi_members;
create trigger tabi_members_history after insert or update or delete on public.tabi_members
  for each row execute function public.tabi_record_history();
drop trigger if exists tabi_places_history on public.tabi_places;
create trigger tabi_places_history after insert or update or delete on public.tabi_places
  for each row execute function public.tabi_record_history();
drop trigger if exists tabi_segments_history on public.tabi_segments;
create trigger tabi_segments_history after insert or update or delete on public.tabi_segments
  for each row execute function public.tabi_record_history();
drop trigger if exists tabi_events_history on public.tabi_events;
create trigger tabi_events_history after insert or update or delete on public.tabi_events
  for each row execute function public.tabi_record_history();
drop trigger if exists tabi_secrets_history on public.tabi_trip_secrets;
create trigger tabi_secrets_history after insert or update or delete on public.tabi_trip_secrets
  for each row execute function public.tabi_record_history();

-- ---------------------------------------------------------------------
-- 4. RLS（行ごとの見る・書く権限）
-- ---------------------------------------------------------------------
alter table public.tabi_trips             enable row level security;
alter table public.tabi_members           enable row level security;
alter table public.tabi_trip_invitations  enable row level security;
alter table public.tabi_places            enable row level security;
alter table public.tabi_segments          enable row level security;
alter table public.tabi_events            enable row level security;
alter table public.tabi_trip_secrets      enable row level security;
alter table public.tabi_change_history    enable row level security;
alter table public.tabi_trip_participants enable row level security;

-- 旅：参加者だけ見られる。作るのは本人。変更は作成者・編集者（細かい制限はトリガー）
drop policy if exists "trips select" on public.tabi_trips;
drop policy if exists "trips insert" on public.tabi_trips;
drop policy if exists "trips update" on public.tabi_trips;
create policy "trips select" on public.tabi_trips for select to authenticated
  using (public.tabi_is_member(id) or owner_id = (select auth.uid()));
create policy "trips insert" on public.tabi_trips for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy "trips update" on public.tabi_trips for update to authenticated
  using (public.tabi_can_edit(id)) with check (public.tabi_can_edit(id));
-- 旅の完全削除は30日後の定期処理だけ（画面からは「削除日時」を入れる）

-- 参加者：同じ旅の参加者だけ見られる。追加は招待関数だけ
drop policy if exists "members select" on public.tabi_members;
drop policy if exists "members update" on public.tabi_members;
drop policy if exists "members delete" on public.tabi_members;
create policy "members select" on public.tabi_members for select to authenticated
  using (public.tabi_is_member(trip_id));
create policy "members update" on public.tabi_members for update to authenticated
  using (public.tabi_is_owner(trip_id) or user_id = (select auth.uid()))
  with check (public.tabi_is_owner(trip_id) or user_id = (select auth.uid()));
-- 作成者はほかの人を外せる。本人は自分で退会できる（作成者の退会はトリガーで禁止）
create policy "members delete" on public.tabi_members for delete to authenticated
  using (public.tabi_is_owner(trip_id) or user_id = (select auth.uid()));

-- 招待：作成者だけ一覧を見られる。作成・無効化・参加は関数経由
drop policy if exists "invitations select" on public.tabi_trip_invitations;
create policy "invitations select" on public.tabi_trip_invitations for select to authenticated
  using (public.tabi_is_owner(trip_id));

-- 地点・移動・予定：参加者は見られる。作成者・編集者だけ書ける
drop policy if exists "places select" on public.tabi_places;
drop policy if exists "places write" on public.tabi_places;
create policy "places select" on public.tabi_places for select to authenticated
  using (public.tabi_is_member(trip_id));
create policy "places write" on public.tabi_places for all to authenticated
  using (public.tabi_can_edit(trip_id)) with check (public.tabi_can_edit(trip_id));

drop policy if exists "segments select" on public.tabi_segments;
drop policy if exists "segments write" on public.tabi_segments;
create policy "segments select" on public.tabi_segments for select to authenticated
  using (public.tabi_is_member(trip_id));
create policy "segments write" on public.tabi_segments for all to authenticated
  using (public.tabi_can_edit(trip_id)) with check (public.tabi_can_edit(trip_id));

drop policy if exists "events select" on public.tabi_events;
drop policy if exists "events write" on public.tabi_events;
create policy "events select" on public.tabi_events for select to authenticated
  using (public.tabi_is_member(trip_id));
create policy "events write" on public.tabi_events for all to authenticated
  using (public.tabi_can_edit(trip_id)) with check (public.tabi_can_edit(trip_id));

-- 機密情報：閲覧範囲に入る人だけ見られる。作成者・編集者だけ書ける
drop policy if exists "secrets select" on public.tabi_trip_secrets;
drop policy if exists "secrets write" on public.tabi_trip_secrets;
create policy "secrets select" on public.tabi_trip_secrets for select to authenticated
  using (public.tabi_can_see_secrets(trip_id));
create policy "secrets write" on public.tabi_trip_secrets for all to authenticated
  using (public.tabi_can_edit(trip_id)) with check (public.tabi_can_edit(trip_id));

-- 変更履歴：参加者は見られる。書き込みは自動処理だけ
drop policy if exists "history select" on public.tabi_change_history;
create policy "history select" on public.tabi_change_history for select to authenticated
  using (public.tabi_is_member(trip_id));

-- 予定ごとの参加者
drop policy if exists "participants select" on public.tabi_trip_participants;
drop policy if exists "participants write" on public.tabi_trip_participants;
create policy "participants select" on public.tabi_trip_participants for select to authenticated
  using (public.tabi_is_member(trip_id));
create policy "participants write" on public.tabi_trip_participants for all to authenticated
  using (public.tabi_can_edit(trip_id)) with check (public.tabi_can_edit(trip_id));

-- 許す操作を最小限にする（ログインしていない人は何もできない）
revoke all on public.tabi_trips, public.tabi_members, public.tabi_trip_invitations, public.tabi_places,
  public.tabi_segments, public.tabi_events, public.tabi_trip_secrets, public.tabi_change_history,
  public.tabi_trip_participants from anon;
revoke all on public.tabi_trips, public.tabi_members, public.tabi_trip_invitations, public.tabi_places,
  public.tabi_segments, public.tabi_events, public.tabi_trip_secrets, public.tabi_change_history,
  public.tabi_trip_participants from authenticated;
grant select, insert, update on public.tabi_trips to authenticated;
grant select, update, delete on public.tabi_members to authenticated;
grant select on public.tabi_trip_invitations to authenticated;
grant select, insert, update, delete on public.tabi_places, public.tabi_segments, public.tabi_events,
  public.tabi_trip_secrets, public.tabi_trip_participants to authenticated;
grant select on public.tabi_change_history to authenticated;

-- ---------------------------------------------------------------------
-- 5. 招待リンク・作成者の交代（データベース内でまとめて処理）
-- ---------------------------------------------------------------------

-- 招待リンクを作る（作成者だけ）。戻り値の秘密コードは1回だけ画面に表示し、保存しない
create or replace function public.tabi_create_invitation(p_trip uuid, p_role text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_code text;
begin
  if not public.tabi_is_owner(p_trip) then raise exception '招待リンクを作れるのは作成者だけです'; end if;
  if p_role not in ('editor','viewer') then raise exception '権限の指定が正しくありません'; end if;
  if exists (select 1 from public.tabi_trips where id = p_trip and deleted_at is not null) then
    raise exception '削除した旅には招待できません';
  end if;
  v_code := translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_');
  insert into public.tabi_trip_invitations(trip_id, code_hash, role, created_by)
  values (p_trip, encode(digest(v_code, 'sha256'), 'hex'), p_role, auth.uid());
  return v_code;
end $$;

-- 招待の中身を確かめる（参加前の確認画面用。旅の名前と権限だけ返す）
create or replace function public.tabi_peek_invitation(p_code text)
returns table (trip_name text, role text, status text)
language plpgsql security definer set search_path = public, extensions as $$
declare v_inv public.tabi_trip_invitations; v_name text;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_inv from public.tabi_trip_invitations
   where code_hash = encode(digest(coalesce(p_code,''), 'sha256'), 'hex');
  if not found then return query select null::text, null::text, 'invalid'; return; end if;
  select name into v_name from public.tabi_trips where id = v_inv.trip_id and deleted_at is null;
  if v_name is null then return query select null::text, null::text, 'invalid'; return; end if;
  if exists (select 1 from public.tabi_members where trip_id = v_inv.trip_id and user_id = auth.uid()) then
    return query select v_name, v_inv.role, 'already_member'; return;
  end if;
  return query select v_name, v_inv.role,
    case when v_inv.revoked_at is not null then 'revoked'
         when v_inv.used_at is not null then 'used'
         when v_inv.expires_at < now() then 'expired'
         else 'ok' end;
end $$;

-- 招待リンクで参加する（ロックしてから確かめ、参加と使用済みを同時に行う）
create or replace function public.tabi_accept_invitation(p_code text, p_display_name text default null)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_inv public.tabi_trip_invitations;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_inv from public.tabi_trip_invitations
   where code_hash = encode(digest(coalesce(p_code,''), 'sha256'), 'hex')
   for update;
  if not found then raise exception 'この招待リンクは使えません'; end if;
  if exists (select 1 from public.tabi_members where trip_id = v_inv.trip_id and user_id = auth.uid()) then
    return v_inv.trip_id; -- すでに参加している（リンクは消費しない）
  end if;
  if v_inv.revoked_at is not null then raise exception 'この招待リンクは無効になっています'; end if;
  if v_inv.used_at is not null then raise exception 'この招待リンクはすでに使われています'; end if;
  if v_inv.expires_at < now() then raise exception 'この招待リンクは期限切れです'; end if;
  if exists (select 1 from public.tabi_trips where id = v_inv.trip_id and deleted_at is not null) then
    raise exception 'この旅は削除されています';
  end if;
  insert into public.tabi_members(trip_id, user_id, role, display_name)
  values (v_inv.trip_id, auth.uid(), v_inv.role,
          left(coalesce(nullif(trim(p_display_name), ''), split_part(auth.jwt() ->> 'email', '@', 1), ''), 40));
  update public.tabi_trip_invitations set used_at = now(), used_by = auth.uid() where id = v_inv.id;
  return v_inv.trip_id;
end $$;

-- 招待リンクを無効にする（作成者だけ）
create or replace function public.tabi_revoke_invitation(p_invitation uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_trip uuid;
begin
  select trip_id into v_trip from public.tabi_trip_invitations where id = p_invitation;
  if v_trip is null or not public.tabi_is_owner(v_trip) then raise exception '無効にできません'; end if;
  update public.tabi_trip_invitations set revoked_at = now() where id = p_invitation and revoked_at is null;
end $$;

-- 作成者を譲る（作成者だけ。元の作成者は編集者になる）
create or replace function public.tabi_transfer_owner(p_trip uuid, p_new_owner uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.tabi_is_owner(p_trip) then raise exception '作成者だけが譲れます'; end if;
  if not exists (select 1 from public.tabi_members where trip_id = p_trip and user_id = p_new_owner) then
    raise exception '相手がこの旅の参加者ではありません';
  end if;
  if p_new_owner = auth.uid() then return; end if;
  perform set_config('tabi.bypass', 'on', true);
  update public.tabi_members set role = 'editor' where trip_id = p_trip and user_id = auth.uid();
  update public.tabi_members set role = 'owner'  where trip_id = p_trip and user_id = p_new_owner;
  update public.tabi_trips set owner_id = p_new_owner where id = p_trip;
  perform set_config('tabi.bypass', 'off', true);
end $$;

revoke all on function public.tabi_create_invitation(uuid, text), public.tabi_peek_invitation(text),
  public.tabi_accept_invitation(text, text), public.tabi_revoke_invitation(uuid),
  public.tabi_transfer_owner(uuid, uuid) from public, anon;
grant execute on function public.tabi_create_invitation(uuid, text), public.tabi_peek_invitation(text),
  public.tabi_accept_invitation(text, text), public.tabi_revoke_invitation(uuid),
  public.tabi_transfer_owner(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. 毎日 午前3時（日本時間）の削除処理
-- ---------------------------------------------------------------------
create or replace function tabi_private.daily_cleanup() returns void
language plpgsql security definer set search_path = public, tabi_private as $$
begin
  -- 削除日時から30日を過ぎた旅（機密情報・履歴なども一緒に消える）
  delete from public.tabi_trips where deleted_at < now() - interval '30 days';
  -- 削除日時から30日を過ぎた移動・予定
  delete from public.tabi_segments where deleted_at < now() - interval '30 days';
  delete from public.tabi_events where deleted_at < now() - interval '30 days';
  -- 旅の終了日から1年を過ぎた変更履歴
  delete from public.tabi_change_history h using public.tabi_trips t
   where h.trip_id = t.id and t.end_date < (now() - interval '1 year')::date;
  -- 期限切れ・使用済み・無効化から30日を過ぎた招待
  delete from public.tabi_trip_invitations
   where greatest(expires_at, coalesce(used_at, expires_at), coalesce(revoked_at, expires_at))
         < now() - interval '30 days'
     and (used_at is not null or revoked_at is not null or expires_at < now());
end $$;
revoke all on function tabi_private.daily_cleanup() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'tabi-daily-cleanup';
select cron.schedule('tabi-daily-cleanup', '0 18 * * *', 'select tabi_private.daily_cleanup()');

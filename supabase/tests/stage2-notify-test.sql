-- 第2段階前半A：送信予定の自動作成のテスト（ローカルのPostgresで実行）
\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users values ('b0000000-0000-0000-0000-000000000001'),('b0000000-0000-0000-0000-000000000002'),('b0000000-0000-0000-0000-000000000003') on conflict do nothing;
set role authenticated;
set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000001'; set request.jwt.claims = '{"email":"owner@x.jp"}';
-- 明日から2日間の旅。明日 9:00 発 → 11:30 着、明日 15:00 発
insert into tabi_trips(name,start_date,end_date) values ('仙台', current_date + 1, current_date + 2) returning id \gset t_
insert into tabi_segments(trip_id,mode,service_name,from_name,to_name,platform,car_no,seat,depart_at,arrive_at)
  values (:'t_id','shinkansen','はやぶさ1号','盛岡','仙台','14','5','3A',
          ((current_date + 1) + time '09:00') at time zone 'Asia/Tokyo', ((current_date + 1) + time '11:30') at time zone 'Asia/Tokyo') returning id \gset s1_
insert into tabi_segments(trip_id,mode,service_name,from_name,to_name,depart_at,arrive_at)
  values (:'t_id','route_bus','市営バス','仙台駅','松島',
          ((current_date + 1) + time '15:00') at time zone 'Asia/Tokyo', ((current_date + 1) + time '16:00') at time zone 'Asia/Tokyo') returning id \gset s2_
insert into tabi_trip_secrets(trip_id,target_type,target_id,value) values (:'t_id','segment',:'s1_id','SECRET999');
select tabi_create_invitation(:'t_id','viewer') as code \gset v_
set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000002'; set request.jwt.claims = '{"email":"v@x.jp"}';
select 'V joined:', tabi_accept_invitation(:'v_code') = :'t_id';

\echo '--- 1. 作られた送信予定（O と V それぞれ）'
reset role;
select '1 live:', u.email_hint, n.kind, to_char(n.send_at at time zone 'Asia/Tokyo','MM/DD HH24:MI'), to_char(n.expires_at at time zone 'Asia/Tokyo','HH24:MI'), n.urgency, n.title, '|', n.body
  from tabi_notifications n
  cross join lateral (select case n.user_id when 'b0000000-0000-0000-0000-000000000001' then 'O' else 'V' end as email_hint) u
 where n.trip_id = :'t_id' and n.status = 'scheduled' order by 2, n.send_at;
select '1 secret in body? (expect f):', bool_or(body like '%SECRET999%' or title like '%SECRET999%') from tabi_notifications;

\echo '--- 2. V は自分の分だけ見える・旅の通知は自分で作れない'
set role authenticated;
set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000002';
select '2 V sees:', count(*), count(*) filter (where user_id <> 'b0000000-0000-0000-0000-000000000002') from tabi_notifications;
insert into tabi_notifications(user_id, title, trip_id, kind) values ('b0000000-0000-0000-0000-000000000002','偽物',:'t_id','depart');
update tabi_notifications set send_at = now() where trip_id = :'t_id';
select '2 V update rows (expect 0 changed):', count(*) from tabi_notifications where send_at <= now() + interval '1 minute' and trip_id = :'t_id';

\echo '--- 3. 出発時刻を変える → 古い予定は取消、新しい時刻で作り直し'
set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000001';
update tabi_segments set depart_at = depart_at + interval '1 hour' where id = :'s1_id';
reset role;
select '3 depart for s1:', status, to_char(send_at at time zone 'Asia/Tokyo','HH24:MI'), target_version from tabi_notifications
 where target_id = :'s1_id' and kind = 'depart' and user_id = 'b0000000-0000-0000-0000-000000000001' order by created_at;

\echo '--- 4. 運休にする → その移動の通知は全部取消'
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000001';
update tabi_segments set status = 'cancelled' where id = :'s2_id';
reset role;
select '4 live for s2 (expect 0):', count(*) from tabi_notifications where target_id = :'s2_id' and status = 'scheduled';
select '4 prep now targets s1:', count(*) from tabi_notifications where kind = 'prep' and status = 'scheduled' and target_id = :'s1_id';

\echo '--- 5. ルール：到着予定をオフ、出発前を15分前に'
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000001';
insert into tabi_notification_rules(trip_id, kind, enabled) values (:'t_id','arrive', false);
insert into tabi_notification_rules(trip_id, kind, minutes) values (:'t_id','depart', 15);
reset role;
select '5 live kinds:', string_agg(kind || '@' || to_char(send_at at time zone 'Asia/Tokyo','HH24:MI'), ', ' order by send_at) from tabi_notifications
 where trip_id = :'t_id' and status = 'scheduled' and user_id = 'b0000000-0000-0000-0000-000000000001';
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000002';
insert into tabi_notification_rules(trip_id, kind, enabled) values (:'t_id','prep', false);
reset role;

\echo '--- 6. 送った（完了）通知は作り直さない'
update tabi_notifications set status = 'done' where kind = 'depart' and status = 'scheduled' and user_id = 'b0000000-0000-0000-0000-000000000001';
select tabi_private.rebuild_trip_notifications(:'t_id');
select '6 depart rows for O (expect done only, no new scheduled):', string_agg(status, ',' order by created_at) from tabi_notifications
 where kind = 'depart' and user_id = 'b0000000-0000-0000-0000-000000000001' and target_id = :'s1_id';

\echo '--- 7. V を外す → V の予定と配信待ちは取消'
insert into tabi_push_subscriptions(user_id, endpoint, p256dh, auth) values ('b0000000-0000-0000-0000-000000000002','https://push.example/v','k','a') returning id \gset sub_
insert into tabi_notification_deliveries(notification_id, subscription_id, user_id, status)
  select id, :'sub_id', user_id, 'retry' from tabi_notifications where user_id = 'b0000000-0000-0000-0000-000000000002' and kind = 'day_before' and status = 'scheduled';
update tabi_notifications set status = 'sending' where user_id = 'b0000000-0000-0000-0000-000000000002' and kind = 'day_before' and status = 'scheduled';
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000001';
delete from tabi_members where user_id = 'b0000000-0000-0000-0000-000000000002';
reset role;
select '7 V live (expect 0):', count(*) from tabi_notifications where user_id = 'b0000000-0000-0000-0000-000000000002' and status = 'scheduled';
select '7 V deliveries:', string_agg(status, ',') from tabi_notification_deliveries where user_id = 'b0000000-0000-0000-0000-000000000002';

\echo '--- 8. 送る直前の確認'
insert into tabi_push_subscriptions(user_id, endpoint, p256dh, auth) values ('b0000000-0000-0000-0000-000000000001','https://push.example/o','k','a');
-- (a) 時刻になった予定：送る
update tabi_notifications set send_at = now() - interval '1 minute' where kind = 'day_before' and status = 'scheduled' and user_id = 'b0000000-0000-0000-0000-000000000001';
-- (b) 版番号が古い予定（トリガーを通さず移動だけ書き換えた状況）：送らない
update tabi_notifications set send_at = now() - interval '1 minute', target_version = target_version - 1 where kind = 'prep' and status = 'scheduled' and user_id = 'b0000000-0000-0000-0000-000000000001';
-- (c) 期限切れの予定：送らない
insert into tabi_notifications(user_id, title, send_at, expires_at) values ('b0000000-0000-0000-0000-000000000001','期限切れテスト', now() - interval '2 hours', now() - interval '1 hour');
select '8 claimed:', title, urgency, kind, expires_at is not null from tabi_claim_due_deliveries(50, null);
select '8 statuses:', kind, title, status from tabi_notifications where user_id = 'b0000000-0000-0000-0000-000000000001' and (kind in ('day_before','prep') or title = '期限切れテスト') and status <> 'cancelled' or (kind = 'prep' and status = 'cancelled' and target_version is not null and user_id = 'b0000000-0000-0000-0000-000000000001' and cancelled_at > now() - interval '5 seconds');

\echo '--- 9. テスト通知（これまでの仕組み）はそのまま使える'
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000001';
select '9 test notif:', tabi_schedule_notification('テスト', '本文', now() + interval '1 minute', 'test-1') is not null;
reset role;

\echo '--- 10. 30日後の完全削除でもエラーにならない'
reset request.jwt.claim.sub; reset request.jwt.claims; -- 定期処理はログインしていない状態で動く
update tabi_trips set deleted_at = now() - interval '31 days';
select tabi_private.daily_cleanup();
select '10 left trips/notifs of trip:', (select count(*) from tabi_trips), (select count(*) from tabi_notifications where trip_id is not null);

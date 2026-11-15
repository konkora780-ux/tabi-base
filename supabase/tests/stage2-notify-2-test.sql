-- 第2段階前半 E・F のテスト
\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users values ('c0000000-0000-0000-0000-000000000001'),('c0000000-0000-0000-0000-000000000002'),('c0000000-0000-0000-0000-000000000003') on conflict do nothing;
set role authenticated;
set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000001'; set request.jwt.claims = '{"email":"owner@x.jp"}';
insert into tabi_trips(name,start_date,end_date) values ('花巻', current_date, current_date + 1) returning id \gset t_
select tabi_create_invitation(:'t_id','editor') as code \gset e_
set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000002'; set request.jwt.claims = '{"email":"e@x.jp"}';
select 'E joined:', tabi_accept_invitation(:'e_code', '編集さん') = :'t_id';
\echo '--- F1. O が移動を2回変える → E にだけ「旅程変更」1件（5分後）'
set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000001';
insert into tabi_segments(trip_id,mode,service_name,depart_at,arrive_at) values (:'t_id','local_train','東北本線', now() + interval '3 hours', now() + interval '4 hours') returning id \gset s_
update tabi_segments set service_name = '釜石線' where id = :'s_id';
insert into tabi_events(trip_id,category,name,start_at) values (:'t_id','meal','昼食', now() + interval '5 hours');
reset role;
select 'F1 change rows:', case user_id when 'c0000000-0000-0000-0000-000000000001' then 'O' else 'E' end, status,
       round(extract(epoch from send_at - now()) / 60), round(extract(epoch from expires_at - now()) / 3600), title
  from tabi_notifications where kind = 'change';
\echo '--- F2. 送った後にまた変える → もう1件'
update tabi_notifications set status = 'done' where kind = 'change';
set role authenticated; set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000002';
update tabi_segments set service_name = '釜石線快速' where id = :'s_id';
reset role;
select 'F2 change rows:', case user_id when 'c0000000-0000-0000-0000-000000000001' then 'O' else 'E' end, status from tabi_notifications where kind = 'change' order by created_at;
\echo '--- F3. 旅程変更をオフにすると作られない'
set role authenticated; set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000001';
insert into tabi_notification_rules(trip_id, kind, enabled) values (:'t_id','change', false);
select 'F3 scheduled change right after off (expect 0):', count(*) from tabi_notifications where kind = 'change' and status = 'scheduled';
update tabi_segments set service_name = 'SL銀河' where id = :'s_id';
reset role;
select 'F3 scheduled change (expect 0):', count(*) from tabi_notifications where kind = 'change' and status = 'scheduled';
\echo '--- F4. 再計算（ルール変更）で旅程変更の予定は消えない'
update tabi_notification_rules set enabled = true where kind = 'change';
set role authenticated; set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000002';
update tabi_events set name = '昼食（そば）' where trip_id = :'t_id';
set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000001';
insert into tabi_notification_rules(trip_id, kind, minutes) values (:'t_id','depart', 20);
reset role;
select 'F4 scheduled change for O (expect 1):', count(*) from tabi_notifications where kind = 'change' and status = 'scheduled' and user_id = 'c0000000-0000-0000-0000-000000000001';
\echo '--- E. 送信状況'
insert into tabi_push_subscriptions(user_id, endpoint, p256dh, auth, device_label) values ('c0000000-0000-0000-0000-000000000002','https://push.example/e','k','a','iPhone/iPad（ホーム画面）') returning id \gset sub_
insert into tabi_notification_deliveries(notification_id, subscription_id, user_id, status, accepted_at, received_at, attempts)
  select id, :'sub_id', user_id, 'accepted', now(), now(), 1 from tabi_notifications where kind = 'change' and user_id = 'c0000000-0000-0000-0000-000000000002' limit 1;
set role authenticated; set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000001';
select 'E owner sees:', display_name, device_label, status, received_at is not null, attempts from tabi_trip_delivery_status(:'t_id');
set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000003';
select 'E outsider:', count(*) from tabi_trip_delivery_status(:'t_id');
reset role;

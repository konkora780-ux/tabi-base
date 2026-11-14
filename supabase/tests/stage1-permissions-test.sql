\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users values ('a0000000-0000-0000-0000-000000000001'),('a0000000-0000-0000-0000-000000000002'),('a0000000-0000-0000-0000-000000000003'),('a0000000-0000-0000-0000-000000000004'),('a0000000-0000-0000-0000-000000000005') on conflict do nothing;
-- O: 作成者
set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000001'; set request.jwt.claims = '{"email":"owner@x.jp"}';
\echo '--- O creates trip'
insert into tabi_trips(name,start_date,end_date) values ('盛岡日帰り','2026-12-01','2026-12-01') returning id \gset t_
\echo :t_id
select 'members after create:', role, display_name from tabi_members;
insert into tabi_segments(trip_id,mode,service_name,from_name,to_name,depart_at,arrive_at) values (:'t_id','local_train','東北本線','北上','盛岡','2026-12-01 00:30Z','2026-12-01 01:20Z') returning id \gset s_
insert into tabi_trip_secrets(trip_id,target_type,target_id,value) values (:'t_id','segment',:'s_id','ABC123');
select 'O sees secret:', count(*) from tabi_trip_secrets;
select tabi_create_invitation(:'t_id','editor') as code \gset e_
select tabi_create_invitation(:'t_id','viewer') as code \gset v_
select tabi_create_invitation(:'t_id','viewer') as code \gset v2_
-- E joins
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000002'; set request.jwt.claims = '{"email":"editor@x.jp"}';
select 'E peek:', * from tabi_peek_invitation(:'e_code');
select 'E accept:', tabi_accept_invitation(:'e_code') = :'t_id';
-- V joins
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000003'; set request.jwt.claims = '{"email":"viewer@x.jp"}';
select 'V accept:', tabi_accept_invitation(:'v_code', 'ビューア') = :'t_id';
\echo '--- X (outsider) tries'
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000004'; set request.jwt.claims = '{"email":"x@x.jp"}';
select 'X used code peek:', status from tabi_peek_invitation(:'v_code');
select 'X accept used (expect error):', tabi_accept_invitation(:'v_code');
select 'X trips/segments/secrets/members/history:', (select count(*) from tabi_trips),(select count(*) from tabi_segments),(select count(*) from tabi_trip_secrets),(select count(*) from tabi_members),(select count(*) from tabi_change_history);
update tabi_segments set seat='X' ; select 'X update rows(above)';
insert into tabi_segments(trip_id,mode) values (:'t_id','walk_bike');
insert into tabi_members(trip_id,user_id,role) values (:'t_id','a0000000-0000-0000-0000-000000000004','editor');
\echo '--- V (viewer)'
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000003';
select 'V sees trip/segments:', (select count(*) from tabi_trips),(select count(*) from tabi_segments);
select 'V secrets (expect 0):', count(*) from tabi_trip_secrets;
update tabi_segments set seat='hack' where id=:'s_id';
select 'V seat unchanged:', seat is null from tabi_segments where id=:'s_id';
delete from tabi_segments; select 'V segments still:', count(*) from tabi_segments;
update tabi_members set role='editor' where user_id=auth.uid();
update tabi_members set display_name='ビューア改' where user_id=auth.uid();
update tabi_trips set secret_scope='all';
select 'V create invite (expect error):', tabi_create_invitation(:'t_id','viewer');
\echo '--- O switches scope to all'
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000001';
update tabi_trips set secret_scope='all';
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000003';
select 'V secrets now (expect 1):', count(*) from tabi_trip_secrets;
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000001';
update tabi_trips set secret_scope='editors';
\echo '--- E (editor)'
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000002';
select 'E secrets:', count(*) from tabi_trip_secrets;
update tabi_segments set seat='7号車12A' where id=:'s_id' and version=1;
select 'E version after:', version from tabi_segments where id=:'s_id';
update tabi_segments set seat='stale' where id=:'s_id' and version=1;
select 'stale update had no effect:', seat from tabi_segments where id=:'s_id';
update tabi_trip_secrets set value='XYZ789';
update tabi_trips set secret_scope='all';
update tabi_trips set deleted_at=now();
update tabi_members set role='editor' where user_id='a0000000-0000-0000-0000-000000000003';
select 'E invite (expect error):', tabi_create_invitation(:'t_id','viewer');
\echo '--- history: no secret values'
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000001';
select 'history mentions secret value? (expect f):', bool_or(coalesce(before_data::text,'')||coalesce(after_data::text,'') like '%XYZ789%' or coalesce(before_data::text,'')||coalesce(after_data::text,'') like '%ABC123%') from tabi_change_history;
select 'history rows:', table_name, op, coalesce(summary,''), new_version from tabi_change_history order by id;
\echo '--- invitations: revoke / expire'
select tabi_revoke_invitation(id) from tabi_trip_invitations where used_at is null;
reset role; update tabi_trip_invitations set expires_at = now() - interval '1 day' where used_at is null and revoked_at is not null; set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000005';
select 'revoked peek:', status from tabi_peek_invitation(:'v2_code');
select 'accept revoked (expect error):', tabi_accept_invitation(:'v2_code');
select 'bad code peek:', status from tabi_peek_invitation('nonsense');
\echo '--- leave / owner rules'
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000001';
delete from tabi_members where user_id = auth.uid();
select 'owner still member:', count(*) from tabi_members where role='owner';
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000003';
delete from tabi_members where user_id = auth.uid();
select 'V after leaving sees trips:', count(*) from tabi_trips;
\echo '--- transfer owner'
set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000001';
select tabi_transfer_owner(:'t_id','a0000000-0000-0000-0000-000000000002');
select 'roles:', user_id, role from tabi_members order by role;
select 'trip owner is E:', owner_id = 'a0000000-0000-0000-0000-000000000002' from tabi_trips;
\echo '--- anon'
reset role; set role anon;
select count(*) from tabi_trips;
reset role;
\echo '--- cleanup cascade'
update tabi_trips set deleted_at = now() - interval '31 days';
select tabi_private.daily_cleanup();
select 'after cleanup trips/members/segments/secrets/history:', (select count(*) from tabi_trips),(select count(*) from tabi_members),(select count(*) from tabi_segments),(select count(*) from tabi_trip_secrets),(select count(*) from tabi_change_history);

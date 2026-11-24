-- DEVELOPMENT TEST ONLY. Run in the ISOLATED mahjong-dev SQL Editor
-- AFTER applying 20261125_safe_readonly_import.sql.
-- Entire test runs in one transaction and ROLLS BACK, including all inserted rooms.
-- Never run this script in the production Supabase project.
--
-- Precondition: replace the UUID below with an EXISTING auth.users.id from the
-- isolated dev project whose account is allowed to own a room.
-- The SQL Editor uses its privileged role and this script simulates auth claims;
-- it is NOT a substitute for tests with a real end-user JWT/RLS session.
begin;
select pg_catalog.set_config('mahjong.dev_test_user_id',
  'REPLACE_WITH_EXISTING_DEV_OWNER_UUID',true);

do $test$
declare
 v_owner uuid;
 v_source_id text := 'test-'||pg_catalog.replace(gen_random_uuid()::text,'-','');
 v_key text;
 v_packet jsonb;
 v_first jsonb;
 v_second jsonb;
 v_conflict boolean := false;
 v_invalid boolean := false;
 v_mutation boolean := false;
 v_delete boolean := false;
 v_room uuid;
 v_normal uuid;
 v_normal_rev integer;
begin
 begin
  v_owner := pg_catalog.current_setting('mahjong.dev_test_user_id',true)::uuid;
 exception when others then
  raise exception 'Set mahjong.dev_test_user_id to an existing dev owner UUID.';
 end;
 if not exists(select 1 from auth.users where id=v_owner) then
  raise exception 'The selected test user does not exist in auth.users.';
 end if;
 perform pg_catalog.set_config('request.jwt.claim.sub',v_owner::text,true);
 perform pg_catalog.set_config('request.jwt.claims',
   pg_catalog.jsonb_build_object('sub',v_owner::text,'role','authenticated','is_anonymous',false)::text,true);
 v_key := 'v22-match:'||v_source_id;
 v_packet := pg_catalog.jsonb_build_object(
  'migrationFormat','v22-readonly','migrationKey',v_key,
  'sharedMatch',pg_catalog.jsonb_build_object(
    'id',v_source_id,'migrationKey',v_key,'migratedReadOnly',true,
    'title','回帰試験','date','2026-11-25T12:00:00',
    'names',pg_catalog.jsonb_build_array('東','南','西','北'),
    'points',pg_catalog.jsonb_build_array(25000,25000,25000,25000),
    'hands','[]'::jsonb,'status','完了',
    'round',0,'dealer',0,'honba',0,'sticks',0
  ),
  'legacyOriginal',pg_catalog.jsonb_build_object(
    'id',v_source_id,'names',pg_catalog.jsonb_build_array('東','南','西','北'),
    'points',pg_catalog.jsonb_build_array(25000,25000,25000,25000),
    'hands','[]'::jsonb,'status','完了'
  )
 );

 -- 1. First insert creates exactly one room and one registry row.
 v_first := public.mahjong_import_v22_readonly(v_key,v_packet);
 if v_first->>'result' <> 'imported' then
  raise exception 'first import did not create a room: %',v_first;
 end if;
 v_room := (v_first->>'room_id')::uuid;
 if (select count(*) from public.mahjong_legacy_imports where owner_id=v_owner and source_key=v_key) <> 1 then
  raise exception 'migration ledger did not record exactly one entry';
 end if;
 if not exists(select 1 from public.mahjong_room_snapshots where room_id=v_room) then
  raise exception 'imported snapshot missing';
 end if;

 -- 2. Identical repeat is idempotent and returns the same room.
 v_second := public.mahjong_import_v22_readonly(v_key,v_packet);
 if v_second->>'result' <> 'already_imported' or v_second->>'room_id' <> v_first->>'room_id' then
  raise exception 'repeat import is not idempotent: %',v_second;
 end if;

 -- 3. Changed packet with the same key is rejected and not overwritten.
 begin
  perform public.mahjong_import_v22_readonly(v_key,
   pg_catalog.jsonb_set(v_packet,'{sharedMatch,title}','"改ざんした対局名"'::jsonb));
 exception when unique_violation then
  v_conflict := true;
 end;
 if not v_conflict then raise exception 'modified duplicate payload was accepted'; end if;

 -- 4. Missing match body is rejected (tests null-safe validation).
 begin
  perform public.mahjong_import_v22_readonly(v_key, v_packet-'sharedMatch');
 exception when invalid_parameter_value then
  v_invalid := true;
 end;
 if not v_invalid then raise exception 'malformed packet was accepted'; end if;

 -- 5. Imported snapshots cannot be updated via ordinary write routes.
 begin
  update public.mahjong_room_snapshots
   set payload=pg_catalog.jsonb_set(payload,'{sharedMatch,title}','"changed"'::jsonb)
   where room_id=v_room;
 exception when insufficient_privilege then
  v_mutation := true;
 end;
 if not v_mutation then raise exception 'imported snapshot could be updated'; end if;

 -- 6. Imported snapshots cannot be deleted.
 begin
  delete from public.mahjong_room_snapshots where room_id=v_room;
 exception when insufficient_privilege then
  v_delete := true;
 end;
 if not v_delete then raise exception 'imported snapshot could be deleted'; end if;

 -- 7. Ordinary room snapshots remain mutable.
 insert into public.mahjong_rooms(owner_id,title,match_date)
 values(v_owner,'通常ルーム回帰試験',date '2026-11-25') returning id into v_normal;
 insert into public.mahjong_room_snapshots(room_id,revision,updated_by,payload)
 values(v_normal,0,v_owner,'{"testCounter":0}'::jsonb);
 update public.mahjong_room_snapshots
 set revision=revision+1, payload='{"testCounter":1}'::jsonb
 where room_id=v_normal returning revision into v_normal_rev;
 if v_normal_rev <> 1 then raise exception 'normal snapshot update was blocked'; end if;

 raise notice 'PASS: insert/retry/conflict/malformed/read-only update/read-only delete/normal write';
end;
$test$;

-- Always discard all test rows. COMMIT must not replace ROLLBACK.
rollback;

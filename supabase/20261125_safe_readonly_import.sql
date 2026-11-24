-- v3.0 DEV ONLY: atomic, idempotent import gate for v2.22 backups.
-- Not applied automatically. Run ONLY in isolated mahjong-dev Supabase after reviewing
-- 20261124_shared_qr_invites.sql and 20261125_player_ids.sql migrations.
-- Do not apply to the production project.
--
-- Client MUST perform the local backup preflight, dry run, and cloud duplicate
-- comparison first. The database performs its OWN checks as the final guard.
-- The imported history stays read-only until full v2.22 compatibility is proven.

begin;

create table if not exists public.mahjong_legacy_imports (
  owner_id uuid not null references auth.users(id) on delete cascade,
  source_key text not null,
  room_id uuid not null unique references public.mahjong_rooms(id) on delete restrict,
  payload_hash bytea not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, source_key),
  constraint mahjong_legacy_source_key_shape
    check (source_key ~ '^v22-match:[a-zA-Z0-9_-]{1,100}$')
);

alter table public.mahjong_legacy_imports enable row level security;
revoke all on public.mahjong_legacy_imports from public, anon, authenticated;

-- Enforce immutability even when an owner attempts to use the regular snapshot
-- editing RPC. The original historical record must not be silently recalculated.
create or replace function public.mahjong_legacy_snapshot_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.payload ? 'migrationKey' and
     old.payload->>'migrationFormat' = 'v22-readonly' then
    raise exception '移行した履歴は読み取り専用です' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists mahjong_legacy_snapshot_immutable on public.mahjong_room_snapshots;
create trigger mahjong_legacy_snapshot_immutable
  before update or delete on public.mahjong_room_snapshots
  for each row execute function public.mahjong_legacy_snapshot_immutable();

create or replace function public.mahjong_import_v22_readonly(
  p_source_key text, p_payload jsonb
)
returns jsonb language plpgsql security definer
set search_path = '' as $$
declare
  v_user uuid := (select auth.uid());
  v_existing public.mahjong_legacy_imports%rowtype;
  v_hash bytea;
  v_room uuid;
  v_source_id text;
  v_match jsonb;
  v_names jsonb;
  v_points jsonb;
  v_hands jsonb;
  v_day date;
  v_title text;
begin
  if v_user is null or
     coalesce((select auth.jwt()->>'is_anonymous')::boolean,false) then
    raise exception '作成者としてログインしてください' using errcode='42501';
  end if;
  if p_source_key is null or
     p_source_key !~ '^v22-match:[a-zA-Z0-9_-]{1,100}$' then
    raise exception '移行元IDの形式が正しくありません' using errcode='22023';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or
     pg_catalog.octet_length(p_payload::text) > 8000000 then
    raise exception '移行データの形式またはサイズが不正です' using errcode='22023';
  end if;

  v_match := p_payload->'sharedMatch';
  v_names := v_match->'names';
  v_points := v_match->'points';
  v_hands := v_match->'hands';
  v_source_id := p_payload->'legacyOriginal'->>'id';
  if p_payload->>'migrationFormat' is distinct from 'v22-readonly'
     or p_payload->>'migrationKey' is distinct from p_source_key
     or v_match->>'migrationKey' is distinct from p_source_key
     or v_match->>'migratedReadOnly' is distinct from 'true'
     or v_source_id is null or p_source_key <> 'v22-match:'||v_source_id
     or v_match->>'id' is distinct from v_source_id
     or jsonb_typeof(p_payload->'legacyOriginal') <> 'object'
     or jsonb_typeof(v_names) <> 'array' or jsonb_array_length(v_names) <> 4
     or jsonb_typeof(v_points) <> 'array' or jsonb_array_length(v_points) <> 4
     or jsonb_typeof(v_hands) <> 'array' or jsonb_array_length(v_hands) > 2000
     or v_match->>'status' not in ('完了','中断','進行中','無効') then
    raise exception '移行データと移行キーの整合性が確認できません' using errcode='22023';
  end if;
  if exists(
     select 1 from pg_catalog.jsonb_array_elements(v_names) as x(value)
     where pg_catalog.jsonb_typeof(x.value)<>'string'
       or pg_catalog.length(pg_catalog.btrim(x.value #>> '{}')) not between 1 and 40
  ) or exists(
     select 1 from pg_catalog.jsonb_array_elements(v_points) as x(value)
     where pg_catalog.jsonb_typeof(x.value)<>'number'
       or (x.value #>> '{}') !~ '^-?[0-9]{1,7}$'
  ) then
    raise exception 'プレイヤー名または点数が不正です' using errcode='22023';
  end if;
  if exists(
      select 1 from pg_catalog.jsonb_array_elements(v_hands) as x(value)
      where pg_catalog.jsonb_typeof(x.value)<>'object'
  ) then
    raise exception '局履歴の形式が不正です' using errcode='22023';
  end if;
  -- Historical display names and immutable IDs must be preserved exactly.
  if v_names is distinct from p_payload->'legacyOriginal'->'names'
     or v_points is distinct from p_payload->'legacyOriginal'->'points'
     or v_hands is distinct from p_payload->'legacyOriginal'->'hands'
     or v_match->'playerIds' is distinct from p_payload->'legacyOriginal'->'playerIds'
  then
    raise exception '元の対局記録と変換結果が一致しません' using errcode='22023';
  end if;
  begin
    v_day := left(v_match->>'date',10)::date;
  exception when others then
    raise exception '対局日が不正です' using errcode='22023';
  end;
  if v_day is null then
    raise exception '対局日を指定してください' using errcode='22023';
  end if;
  v_title := coalesce(nullif(pg_catalog.btrim(v_match->>'title'),''),'移行した半荘');
  if pg_catalog.length(v_title)>100 then
    raise exception '半荘名は100文字以内にしてください' using errcode='22023';
  end if;

  v_hash := pg_catalog.sha256(pg_catalog.convert_to(p_payload::text,'UTF8'));

  -- Serialize same-user / same-source imports, including concurrent devices.
  -- The unique primary key remains authoritative even on advisory-lock collision.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user::text||':'||p_source_key,0)
  );
  select * into v_existing from public.mahjong_legacy_imports
     where owner_id=v_user and source_key=p_source_key;

  if found then
    if v_existing.payload_hash is distinct from v_hash then
      raise exception '同一移行キーの内容が以前の取り込みと異なります'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'result','already_imported','room_id',v_existing.room_id
    );
  end if;

  -- Conservative collision guard for rooms created before migration-key support.
  if exists(
    select 1 from public.mahjong_rooms r
    join public.mahjong_room_snapshots ss on ss.room_id=r.id
    where r.owner_id=v_user
      and ss.payload->'sharedMatch'->>'id'=v_source_id
  ) then
    raise exception '同じ対局IDの既存ルームがあります。手動で照合してください'
      using errcode='23505';
  end if;

  -- All three inserts are in the SAME transaction. On any failure,
  -- neither the room, the snapshot, nor the import ledger survives.
  insert into public.mahjong_rooms(owner_id,title,match_date)
    values(v_user,v_title,v_day)
    returning id into v_room;

  insert into public.mahjong_room_snapshots(room_id,revision,updated_by,payload)
    values(v_room,0,v_user,p_payload);

  insert into public.mahjong_legacy_imports(owner_id,source_key,room_id,payload_hash)
    values(v_user,p_source_key,v_room,v_hash);

  return pg_catalog.jsonb_build_object('result','imported','room_id',v_room);
end;
$$;

revoke all on function public.mahjong_import_v22_readonly(text,jsonb)
  from public, anon, authenticated;
grant execute on function public.mahjong_import_v22_readonly(text,jsonb)
  to authenticated;

commit;

-- Manual post-deployment checks in the isolated DEV project only:
-- select owner_id,source_key,room_id,created_at from public.mahjong_legacy_imports;
-- Importing identical bytes twice must return "already_imported" with the same room_id.
-- Changing payload with the same source_key must fail and leave DB unchanged.
-- Owner A and owner B may each import their own source_key without leaking records.
-- Attempts to update/delete imported snapshots must fail; normal rooms remain writable.

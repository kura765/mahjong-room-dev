-- Self-contained Postgres fixture for CI only.
-- Replaces Supabase auth helpers and existing tables with MINIMAL test doubles.
-- Not intended for any real Supabase database.
create schema if not exists auth;
do $$
begin
 if not exists(select 1 from pg_catalog.pg_roles where rolname='authenticated') then
  execute 'create role authenticated nologin';
 end if;
 if not exists(select 1 from pg_catalog.pg_roles where rolname='anon') then
  execute 'create role anon nologin';
 end if;
end $$;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
 select nullif(pg_catalog.current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
create function auth.jwt() returns jsonb language sql stable as $$
 select coalesce(nullif(pg_catalog.current_setting('request.jwt.claims',true),'')::jsonb, '{}'::jsonb)
$$;
insert into auth.users(id) values ('00000000-0000-4000-8000-000000000123');
create table public.mahjong_rooms (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id),
 title text not null,
 match_date date not null,
 created_at timestamptz not null default now()
);
create table public.mahjong_room_snapshots (
 room_id uuid primary key references public.mahjong_rooms(id) on delete cascade,
 revision integer not null default 0,
 updated_by uuid references auth.users(id),
 payload jsonb not null
);

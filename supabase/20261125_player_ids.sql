-- v3.0 development migration: persistent owner-scoped player identities.
-- Apply ONLY in the isolated mahjong-dev Supabase project's SQL Editor.
-- Execute after the existing private rooms / invitation migrations.
-- No existing rooms, snapshots, or hand history are modified.
create table if not exists public.mahjong_players (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (length(btrim(display_name)) between 1 and 40 and display_name=btrim(display_name)),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists mahjong_players_owner_idx on public.mahjong_players(owner_id);
create unique index if not exists mahjong_players_active_name_unique
  on public.mahjong_players(owner_id, lower(display_name))
  where deleted_at is null;
alter table public.mahjong_players enable row level security;
revoke all on public.mahjong_players from public, anon, authenticated;
grant select, insert, update on public.mahjong_players to authenticated;

drop policy if exists "mahjong_players_owner_read" on public.mahjong_players;
create policy "mahjong_players_owner_read" on public.mahjong_players
 for select to authenticated using (
   owner_id=(select auth.uid())
   and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false
 );
drop policy if exists "mahjong_players_owner_insert" on public.mahjong_players;
create policy "mahjong_players_owner_insert" on public.mahjong_players
 for insert to authenticated with check (
   owner_id=(select auth.uid())
   and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false
 );
drop policy if exists "mahjong_players_owner_update" on public.mahjong_players;
create policy "mahjong_players_owner_update" on public.mahjong_players
 for update to authenticated
 using (owner_id=(select auth.uid()) and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false)
 with check (owner_id=(select auth.uid()) and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false);

-- Player IDs/owners must never be changed. Archiving is soft-delete via deleted_at.
create or replace function public.mahjong_players_prevent_identity_update()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.id is distinct from old.id or new.owner_id is distinct from old.owner_id then
    raise exception 'プレイヤーIDと作成者は変更できません' using errcode='42501';
  end if;
  return new;
end;
$$;
drop trigger if exists mahjong_players_identity_immutable on public.mahjong_players;
create trigger mahjong_players_identity_immutable
 before update on public.mahjong_players for each row
 execute function public.mahjong_players_prevent_identity_update();

-- Matches created before this migration have names[] but no playerIds[].
-- Do NOT backfill by name: distinct historical identities might share the same name.
-- The app must write both names[] (historical snapshot) and playerIds[] (immutable identities)
-- for all newly saved matches. Old records remain valid and unlinked until explicit reconciliation.

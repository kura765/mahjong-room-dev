-- v3.0 development-only migration. Apply to isolated mahjong-dev AFTER older room/invite migrations.
-- Public share links: reusable for 24h; existing membership survives expiry and invite revocation.
-- Never put service_role or secret API keys in invite URLs.
create table if not exists public.mahjong_room_share_links (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references public.mahjong_rooms(id) on delete cascade,
 token_hash bytea not null unique,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 revoked_at timestamptz
);
create index if not exists mahjong_share_links_room_idx on public.mahjong_room_share_links(room_id);
alter table public.mahjong_room_share_links enable row level security;
revoke all on public.mahjong_room_share_links from public, anon, authenticated;

-- Anonymous identities use authenticated role. Block room ownership/creation by anonymous identities.
drop policy if exists "rooms_create_self" on public.mahjong_rooms;
create policy "rooms_create_self" on public.mahjong_rooms for insert to authenticated
with check (
 owner_id=(select auth.uid())
 and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false
);
-- In case an owner identity becomes anonymous (e.g. unexpected auth state).
drop policy if exists "rooms_owner_update" on public.mahjong_rooms;
create policy "rooms_owner_update" on public.mahjong_rooms for update to authenticated
using (owner_id=(select auth.uid()) and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false)
with check (owner_id=(select auth.uid()) and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false);
drop policy if exists "rooms_owner_delete" on public.mahjong_rooms;
create policy "rooms_owner_delete" on public.mahjong_rooms for delete to authenticated
using (owner_id=(select auth.uid()) and coalesce((select auth.jwt()->>'is_anonymous')::boolean,false)=false);

create or replace function public.mahjong_create_shared_invite(p_room_id uuid)
returns text language plpgsql security definer set search_path=''
as $$
declare
 v_user uuid := (select auth.uid());
 v_code text;
begin
 if v_user is null or coalesce((select auth.jwt()->>'is_anonymous')::boolean,false) then
   raise exception '作成者としてログインしてください' using errcode='42501';
 end if;
 if not exists(select 1 from public.mahjong_rooms where id=p_room_id and owner_id=v_user) then
   raise exception '招待する権限がありません' using errcode='42501';
 end if;
 -- Reissue at any time. Old links remain valid until expiry/revocation.
 v_code := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
 insert into public.mahjong_room_share_links(room_id,token_hash,created_by,expires_at)
 values (p_room_id,pg_catalog.sha256(pg_catalog.convert_to(v_code,'UTF8')),v_user,now()+interval '24 hours');
 return v_code;
end;
$$;

create or replace function public.mahjong_join_shared_invite(p_code text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
 v_user uuid := (select auth.uid());
 v_room uuid;
begin
 if v_user is null then raise exception '認証できませんでした' using errcode='28000'; end if;
 if p_code is null or p_code !~ '^[a-f0-9]{64}$' then
   raise exception '招待URLの形式が不正です' using errcode='22023';
 end if;
 select room_id into v_room
 from public.mahjong_room_share_links
 where token_hash=pg_catalog.sha256(pg_catalog.convert_to(p_code,'UTF8'))
 and revoked_at is null and expires_at>now();
 if v_room is null then raise exception '招待URLが期限切れ、または無効です' using errcode='22023'; end if;
 insert into public.mahjong_room_members(room_id,user_id) values(v_room,v_user)
 on conflict(room_id,user_id) do nothing;
 return v_room;
end;
$$;

create or replace function public.mahjong_revoke_shared_invites(p_room_id uuid)
returns integer language plpgsql security definer set search_path=''
as $$
declare
 v_count integer;
begin
 if (select auth.uid()) is null or coalesce((select auth.jwt()->>'is_anonymous')::boolean,false) or
 not exists(select 1 from public.mahjong_rooms where id=p_room_id and owner_id=(select auth.uid())) then
  raise exception '招待を停止する権限がありません' using errcode='42501';
 end if;
 update public.mahjong_room_share_links set revoked_at=now()
 where room_id=p_room_id and revoked_at is null and expires_at>now();
 get diagnostics v_count=row_count;
 return v_count;
end;
$$;

revoke all on function public.mahjong_create_shared_invite(uuid) from public, anon;
revoke all on function public.mahjong_join_shared_invite(text) from public, anon;
revoke all on function public.mahjong_revoke_shared_invites(uuid) from public, anon;
grant execute on function public.mahjong_create_shared_invite(uuid) to authenticated;
grant execute on function public.mahjong_join_shared_invite(text) to authenticated;
grant execute on function public.mahjong_revoke_shared_invites(uuid) to authenticated;
-- Disable legacy single-use links after switching to reusable invites.
revoke execute on function public.mahjong_create_viewer_invite(uuid) from authenticated;
revoke execute on function public.mahjong_accept_viewer_invite(text) from authenticated;
-- Membership rows are deliberately not deleted on link expiry/revocation.

-- Chat app schema. Run this once in Supabase → SQL Editor on a fresh project.
-- Privacy is enforced here with Row Level Security: you can only read a chat
-- (DM or group) if you're a member of it. Everyone is a member of the main chat.

-- ============ tables ============
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 2 and 20),
  color      text not null default '#ee4d8b' check (char_length(color) <= 9),
  emoji      text not null default '' check (char_length(emoji) <= 8),
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
create unique index profiles_name_lower on public.profiles (lower(name));

create table public.rooms (
  id         uuid primary key default gen_random_uuid(),
  type       text not null check (type in ('main','dm','group')),
  name       text check (name is null or char_length(name) between 1 and 40),
  dm_key     text unique,                       -- "<uid>:<uid>" so each pair has one DM
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  last_text  text,                              -- preview shown in the sidebar
  last_uid   uuid,
  last_at    timestamptz
);

create table public.room_members (
  room_id   uuid references public.rooms(id) on delete cascade,
  user_id   uuid references public.profiles(id) on delete cascade,
  last_read timestamptz not null default now(),
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index room_members_user on public.room_members (user_id);

create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete set null,
  system     boolean not null default false,
  text       text not null default '',
  reply      jsonb check (reply is null or pg_column_size(reply) < 1024),
  reactions  jsonb not null default '{}'::jsonb,  -- {"🔥": {"<uid>": true}}
  deleted    boolean not null default false,
  created_at timestamptz not null default now(),
  check (deleted or system or char_length(text) between 1 and 1000)
);
create index messages_room_time on public.messages (room_id, created_at desc);

insert into public.rooms (id, type, name)
values ('00000000-0000-0000-0000-000000000001', 'main', 'The Main Chat');

-- ============ helpers ============
create function public.is_member(rid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from room_members where room_id = rid and user_id = auth.uid());
$$;

create function public.my_name() returns text
language sql stable security definer set search_path = public as $$
  select name from profiles where id = auth.uid();
$$;

create function public.post_system(rid uuid, msg text) returns void
language sql security definer set search_path = public as $$
  insert into messages (room_id, system, text) values (rid, true, msg);
$$;
revoke execute on function public.post_system(uuid, text) from public, anon, authenticated;

-- ============ triggers ============
-- clients can't backdate messages or pre-fill reactions
create function public.messages_before_insert() returns trigger
language plpgsql as $$
begin
  new.created_at := now();
  new.deleted := false;
  new.reactions := '{}'::jsonb;
  return new;
end $$;
create trigger messages_before_insert before insert on public.messages
for each row execute function public.messages_before_insert();

-- keep the sidebar preview up to date
create function public.messages_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update rooms set last_text = left(new.text, 140), last_uid = new.user_id, last_at = new.created_at
  where id = new.room_id;
  return null;
end $$;
create trigger messages_after_insert after insert on public.messages
for each row execute function public.messages_after_insert();

-- new people join the main chat automatically
create function public.handle_new_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into room_members (room_id, user_id)
  values ('00000000-0000-0000-0000-000000000001', new.id) on conflict do nothing;
  perform post_system('00000000-0000-0000-0000-000000000001', new.name || ' joined the chat 👋');
  return null;
end $$;
create trigger on_profile_created after insert on public.profiles
for each row execute function public.handle_new_profile();

-- ============ actions (called with supabase.rpc) ============
create function public.start_dm(other uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); k text; rid uuid;
begin
  if me is null or other is null or other = me then raise exception 'invalid user'; end if;
  if not exists (select 1 from profiles where id = other) then raise exception 'user not found'; end if;
  k := least(me::text, other::text) || ':' || greatest(me::text, other::text);
  insert into rooms (type, dm_key, created_by) values ('dm', k, me) on conflict (dm_key) do nothing;
  select id into rid from rooms where dm_key = k;
  insert into room_members (room_id, user_id) values (rid, me), (rid, other) on conflict do nothing;
  return rid;
end $$;

create function public.create_group(gname text, member_ids uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rid uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into rooms (type, name, created_by) values ('group', trim(gname), me) returning id into rid;
  insert into room_members (room_id, user_id)
    select rid, p.id from profiles p where p.id = me or p.id = any(member_ids)
  on conflict do nothing;
  perform post_system(rid, my_name() || ' created “' || trim(gname) || '”');
  return rid;
end $$;

create function public.add_members(rid uuid, member_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare added text;
begin
  if not is_member(rid) or (select type from rooms where id = rid) is distinct from 'group' then
    raise exception 'not allowed';
  end if;
  with ins as (
    insert into room_members (room_id, user_id)
      select rid, id from profiles where id = any(member_ids)
    on conflict do nothing returning user_id
  )
  select string_agg(p.name, ', ') into added from ins join profiles p on p.id = ins.user_id;
  if added is not null then perform post_system(rid, my_name() || ' added ' || added); end if;
end $$;

create function public.leave_group(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select type from rooms where id = rid) is distinct from 'group' then
    raise exception 'you can only leave groups';
  end if;
  delete from room_members where room_id = rid and user_id = auth.uid();
  if found then perform post_system(rid, my_name() || ' left the group'); end if;
end $$;

create function public.rename_group(rid uuid, gname text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member(rid) or (select type from rooms where id = rid) is distinct from 'group' then
    raise exception 'not allowed';
  end if;
  update rooms set name = trim(gname) where id = rid;
  perform post_system(rid, my_name() || ' renamed the group to “' || trim(gname) || '”');
end $$;

create function public.toggle_reaction(mid uuid, emoji text) returns void
language plpgsql security definer set search_path = public as $$
declare rid uuid; cur jsonb; me text := auth.uid()::text;
begin
  if char_length(emoji) not between 1 and 8 then raise exception 'bad emoji'; end if;
  select room_id, reactions into rid, cur from messages where id = mid and not deleted for update;
  if rid is null or not is_member(rid) then raise exception 'not allowed'; end if;
  if cur -> emoji ? me then
    cur := jsonb_set(cur, array[emoji], (cur -> emoji) - me);
    if cur -> emoji = '{}'::jsonb then cur := cur - emoji; end if;
  else
    cur := jsonb_set(cur, array[emoji], coalesce(cur -> emoji, '{}'::jsonb) || jsonb_build_object(me, true));
  end if;
  update messages set reactions = cur where id = mid;
end $$;

create function public.delete_message(mid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare rid uuid; ts timestamptz;
begin
  update messages set deleted = true, text = '', reactions = '{}'::jsonb, reply = null
  where id = mid and user_id = auth.uid() and not system
  returning room_id, created_at into rid, ts;
  if rid is not null then
    update rooms set last_text = 'message deleted' where id = rid and last_at = ts;
  end if;
end $$;

create function public.mark_read(rid uuid) returns void
language sql security definer set search_path = public as $$
  update room_members set last_read = now() where room_id = rid and user_id = auth.uid();
$$;

revoke execute on function public.start_dm(uuid), public.create_group(text, uuid[]),
  public.add_members(uuid, uuid[]), public.leave_group(uuid), public.rename_group(uuid, text),
  public.toggle_reaction(uuid, text), public.delete_message(uuid), public.mark_read(uuid)
  from public, anon;
grant execute on function public.start_dm(uuid), public.create_group(text, uuid[]),
  public.add_members(uuid, uuid[]), public.leave_group(uuid), public.rename_group(uuid, text),
  public.toggle_reaction(uuid, text), public.delete_message(uuid), public.mark_read(uuid)
  to authenticated;

-- ============ row level security ============
alter table public.profiles     enable row level security;
alter table public.rooms        enable row level security;
alter table public.room_members enable row level security;
alter table public.messages     enable row level security;

create policy "profiles are public to signed-in users" on public.profiles
  for select to authenticated using (true);
create policy "create your own profile" on public.profiles
  for insert to authenticated with check (id = auth.uid());
create policy "edit your own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "see rooms you're in" on public.rooms
  for select to authenticated using (is_member(id));

create policy "see members of rooms you're in" on public.room_members
  for select to authenticated using (user_id = auth.uid() or is_member(room_id));

create policy "read messages in rooms you're in" on public.messages
  for select to authenticated using (is_member(room_id));
create policy "post in rooms you're in" on public.messages
  for insert to authenticated with check (user_id = auth.uid() and not system and is_member(room_id));
-- no update/delete policies: edits go through the functions above

-- ============ realtime ============
alter publication supabase_realtime add table public.profiles, public.rooms, public.room_members, public.messages;

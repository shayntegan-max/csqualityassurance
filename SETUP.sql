-- ============================================================
-- QA Audit Tool — real per-agent auth + row-level security
-- Run this whole script once in Supabase SQL Editor.
-- ============================================================

-- Clean up the old open table from the passcode version (safe to run even if it doesn't exist)
drop table if exists kv_store;

create extension if not exists pgcrypto;

-- ---------- profiles ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null default 'agent' check (role in ('admin','reviewer','agent')),
  created_at timestamptz default now()
);
alter table profiles enable row level security;

-- Auto-create a profile row whenever you add a user in Authentication.
-- Reads "name" and "role" from the user's metadata if you set them when
-- creating the user; defaults to role "agent" if not specified.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', new.email),
    coalesce(new.raw_user_meta_data->>'role', 'agent')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Helper function to check the logged-in user's own role without
-- causing recursive RLS lookups.
create or replace function public.my_role()
returns text
language sql
security definer
stable
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Everyone can see their own profile; reviewers/admins can see everyone
-- (needed to populate the agent picker when scoring a case).
create policy "read own or staff" on profiles for select
  using ( auth.uid() = id or public.my_role() in ('reviewer','admin') );

-- Admins can change someone's role from inside the app (e.g. promote an
-- agent to reviewer) without needing the Supabase dashboard.
create policy "admin can update roles" on profiles for update
  using ( public.my_role() = 'admin' )
  with check ( true );

-- ---------- reviews ----------
create table reviews (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references profiles(id),
  reviewer_id uuid not null references profiles(id),
  case_id text,
  issue_type text,
  review_date date,
  rows jsonb not null default '[]',
  overall_notes text,
  pct numeric,
  earned numeric,
  possible numeric,
  band_key text,
  band_label text,
  saved_at timestamptz default now(),
  comments jsonb not null default '[]'
);
alter table reviews enable row level security;

-- Only reviewers/admins can create reviews.
create policy "staff can insert" on reviews for insert
  with check ( public.my_role() in ('reviewer','admin') );

-- Agents can only ever see rows about themselves; reviewers/admins see all.
create policy "own or staff can select" on reviews for select
  using ( agent_id = auth.uid() or public.my_role() in ('reviewer','admin') );

-- Needed so an agent can post a dispute comment on their own review,
-- and staff can post calibration comments on any review.
create policy "own or staff can update" on reviews for update
  using ( agent_id = auth.uid() or public.my_role() in ('reviewer','admin') )
  with check ( agent_id = auth.uid() or public.my_role() in ('reviewer','admin') );

-- Only admins can delete a review.
create policy "admin can delete" on reviews for delete
  using ( public.my_role() = 'admin' );

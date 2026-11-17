-- RHL Journal: run this once in Supabase (SQL Editor > New query > paste > Run).
-- Each person can only ever read and change their own trades, notes and screenshots.

create table if not exists public.trades (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  id text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table if not exists public.journal (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  id text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

alter table public.trades enable row level security;
alter table public.journal enable row level security;

drop policy if exists "own trades" on public.trades;
create policy "own trades" on public.trades for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own journal" on public.journal;
create policy "own journal" on public.journal for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- private bucket for chart screenshots, one folder per person
insert into storage.buckets (id, name, public) values ('shots', 'shots', false)
  on conflict (id) do nothing;

drop policy if exists "own shots read" on storage.objects;
create policy "own shots read" on storage.objects for select
  using (bucket_id = 'shots' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own shots write" on storage.objects;
create policy "own shots write" on storage.objects for insert
  with check (bucket_id = 'shots' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own shots update" on storage.objects;
create policy "own shots update" on storage.objects for update
  using (bucket_id = 'shots' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own shots delete" on storage.objects;
create policy "own shots delete" on storage.objects for delete
  using (bucket_id = 'shots' and (storage.foldername(name))[1] = auth.uid()::text);

-- RHL Journal: MT5 sync. Run this once in Supabase (SQL Editor > New query > paste > Run),
-- after supabase-setup.sql. It lets the RHL Journal Sync add-on in MT5 send closed trades
-- to your journal using a private sync code instead of your password.

-- one sync code per person; only you can see or change yours
create table if not exists public.sync_tokens (
  user_id uuid primary key default auth.uid() references auth.users on delete cascade,
  token text not null unique,
  created_at timestamptz not null default now()
);
alter table public.sync_tokens enable row level security;
drop policy if exists "own sync code" on public.sync_tokens;
create policy "own sync code" on public.sync_tokens for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- MT5 calls this with the sync code and a list of closed positions.
-- New positions are added as ungraded trades. Positions already in the journal only get
-- the broker facts refreshed (prices, times, lots, result); your planned stop, grade,
-- checklist, notes, tags, mistakes and screenshot are never touched.
create or replace function public.mt5_push(p_token text, p_trades jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  t jsonb;
  n integer := 0;
  v_id text;
  v_old jsonb;
  v_new jsonb;
  v_now bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if p_token is null or length(p_token) < 20 then
    raise exception 'invalid sync code';
  end if;
  select user_id into v_user from sync_tokens where token = p_token;
  if v_user is null then
    raise exception 'invalid sync code';
  end if;
  if p_trades is null or jsonb_typeof(p_trades) <> 'array' or jsonb_array_length(p_trades) > 200 then
    raise exception 'bad payload';
  end if;

  for t in select value from jsonb_array_elements(p_trades) loop
    if coalesce(t->>'ticket', '') !~ '^[0-9]{1,20}$' then
      continue;
    end if;
    v_id := 'mt5-' || (t->>'ticket');
    v_new := jsonb_build_object(
      'id', v_id,
      'ticket', t->>'ticket',
      'source', 'mt5',
      'symbol', left(coalesce(t->>'symbol', ''), 20),
      'dir', case when t->>'dir' = 'Short' then 'Short' else 'Long' end,
      'lots', left(coalesce(t->>'lots', ''), 20),
      'open', left(coalesce(t->>'open', ''), 30),
      'close', left(coalesce(t->>'close', ''), 30),
      'entry', left(coalesce(t->>'entry', ''), 30),
      'exit', left(coalesce(t->>'exit', ''), 30),
      'pnl', left(coalesce(t->>'pnl', ''), 30),
      '_stamp', v_now
    );

    select data into v_old from trades where user_id = v_user and id = v_id;
    if v_old is null then
      v_new := v_new || jsonb_build_object(
        'model', '15M',
        'sl', left(coalesce(t->>'sl', ''), 30),
        'tp', left(coalesce(t->>'tp', ''), 30),
        's4h', '', 's1h', '', 's15', '',
        'checks', jsonb_build_object('signal', false, 'brk1h', false, 'retest', false, 'prot', false, 'cont', false, 'htf', false),
        'graded', false, 'plan', '', 'tags', '[]'::jsonb, 'mistakes', '[]'::jsonb,
        'notes', '', 'shot', '', 'shotUrl', ''
      );
      insert into trades (user_id, id, data, updated_at) values (v_user, v_id, v_new, now());
    else
      update trades set data = v_old || v_new, updated_at = now()
        where user_id = v_user and id = v_id;
    end if;
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke all on function public.mt5_push(text, jsonb) from public;
grant execute on function public.mt5_push(text, jsonb) to anon, authenticated;

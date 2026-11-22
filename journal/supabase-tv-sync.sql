-- RHL Journal: TradingView grade alerts + setups log. Run this once in Supabase
-- (SQL Editor > New query > paste > Run), after supabase-setup.sql and supabase-mt5-sync.sql.

-- every graded setup from TradingView (and any you add by hand) lands here
create table if not exists public.setups (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  id text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.setups enable row level security;
drop policy if exists "own setups" on public.setups;
create policy "own setups" on public.setups for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Called by the journal's webhook with your sync code and one parsed grade alert.
-- The same setup (same market and direction within 6 hours, not yet linked to a trade)
-- is updated in place when a better grade arrives, instead of making a duplicate.
create or replace function public.tv_push(p_token text, p_alert jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_sym text := upper(left(coalesce(p_alert->>'symbol', ''), 20));
  v_dir text := case when p_alert->>'dir' = 'Short' then 'Short' else 'Long' end;
  v_score int := coalesce(nullif(p_alert->>'score', '')::int, 0);
  v_id text;
  v_old jsonb;
  v_now bigint := (extract(epoch from now()) * 1000)::bigint;
  v_new jsonb;
begin
  if p_token is null or length(p_token) < 20 then raise exception 'invalid sync code'; end if;
  select user_id into v_user from sync_tokens where token = p_token;
  if v_user is null then raise exception 'invalid sync code'; end if;
  if v_sym = '' or p_alert is null or jsonb_typeof(p_alert) <> 'object' then raise exception 'bad payload'; end if;

  v_new := jsonb_build_object(
    'symbol', v_sym,
    'dir', v_dir,
    'model', left(coalesce(p_alert->>'model', '15M'), 8),
    'setup', case when p_alert->>'setup' = 'Impulsive' then 'Impulsive' else 'Normal' end,
    'grade', left(coalesce(p_alert->>'grade', ''), 10),
    'score', v_score,
    'entry', left(coalesce(p_alert->>'entry', ''), 30),
    'sl', left(coalesce(p_alert->>'sl', ''), 30),
    'tp', left(coalesce(p_alert->>'tp', ''), 30),
    'rr', left(coalesce(p_alert->>'rr', ''), 10),
    'session', left(coalesce(p_alert->>'session', ''), 30),
    's4h', left(coalesce(p_alert->>'s4h', ''), 10),
    's1h', left(coalesce(p_alert->>'s1h', ''), 10),
    's15', left(coalesce(p_alert->>'s15', ''), 10),
    'checks', coalesce(p_alert->'checks', '{}'::jsonb),
    'raw', left(coalesce(p_alert->>'raw', ''), 600),
    'time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'source', 'tv',
    '_stamp', v_now
  );

  select id, data into v_id, v_old from setups
   where user_id = v_user
     and data->>'symbol' = v_sym and data->>'dir' = v_dir
     and coalesce(data->>'status', 'new') = 'new'
     and updated_at > now() - interval '6 hours'
   order by updated_at desc limit 1;

  if v_id is null then
    v_id := 'tv-' || v_now::text;
    insert into setups (user_id, id, data, updated_at)
      values (v_user, v_id, v_new || jsonb_build_object('id', v_id, 'status', 'new', 'outcome', '', 'notes', '', 'firstTime', v_new->>'time'), now());
  elsif v_score >= coalesce(nullif(v_old->>'score', '')::int, 0) then
    update setups set data = v_old || v_new, updated_at = now() where user_id = v_user and id = v_id;
  end if;
  return v_id;
end;
$$;

revoke all on function public.tv_push(text, jsonb) from public;
grant execute on function public.tv_push(text, jsonb) to anon, authenticated;

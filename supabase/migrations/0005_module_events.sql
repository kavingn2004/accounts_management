-- =============================================================================
-- 0005 — module_events  (generic per-row value ledger for every module)
-- =============================================================================
-- Savings and investments overwrite their values in place, so the app has no
-- record of how a balance got where it is and no way to chart growth. This
-- table logs every value-changing action on any module: parent_id = source row
-- id, parent_type = source table, field = the column that moved, kind =
-- open/increment/decrement/set, and balance_after = the value that resulted.
--
-- balance_after is recorded at write time so curves are read rather than
-- re-derived; a forward rebuild would drift whenever a row is edited by hand,
-- and the chart would then contradict the total printed above it.
--
-- Safe to run on an existing project: creates the table + owner-only RLS only
-- if it isn't already present.
-- =============================================================================

create extension if not exists pgcrypto;

do $$
begin
  if not exists (
    select 1 from pg_tables
    where schemaname = 'public' and tablename = 'module_events'
  ) then
    create table public.module_events (
      id         uuid        primary key default gen_random_uuid(),
      user_id    uuid        not null default auth.uid()
                             references auth.users (id) on delete cascade,
      data       jsonb       not null default '{}'::jsonb,
      created_at timestamptz not null default now()
    );

    create index idx_module_events_user
      on public.module_events (user_id, created_at desc);

    alter table public.module_events enable row level security;

    create policy module_events_select_own on public.module_events
      for select using (user_id = auth.uid());
    create policy module_events_insert_own on public.module_events
      for insert with check (user_id = auth.uid());
    create policy module_events_update_own on public.module_events
      for update using (user_id = auth.uid()) with check (user_id = auth.uid());
    create policy module_events_delete_own on public.module_events
      for delete using (user_id = auth.uid());
  end if;
end;
$$;

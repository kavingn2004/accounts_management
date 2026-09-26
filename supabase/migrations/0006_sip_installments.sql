-- =============================================================================
-- 0006 — sip_installments  (per-SIP purchase ledger)
-- =============================================================================
-- Adds one more JSONB-backed app "table", matching the model in schema.sql.
--
-- The SIP engine writes one row per installment (parent_id = the investments
-- row id, date, amount, nav, nav_date, units, source, skipped, account,
-- cash_posted). Units held — and therefore the holding's value — are derived
-- by summing this ledger, so it is the source of truth for a SIP rather than a
-- convenience log.
--
-- Safe to run on an existing project: creates the table + owner-only RLS only
-- if it isn't already present. Without it the app still runs; SIP rows simply
-- have no ledger to read and stay at zero units.
-- =============================================================================

create extension if not exists pgcrypto;

do $$
begin
  if not exists (
    select 1 from pg_tables
    where schemaname = 'public' and tablename = 'sip_installments'
  ) then
    create table public.sip_installments (
      id         uuid        primary key default gen_random_uuid(),
      user_id    uuid        not null default auth.uid()
                             references auth.users (id) on delete cascade,
      data       jsonb       not null default '{}'::jsonb,
      created_at timestamptz not null default now()
    );

    create index idx_sip_installments_user
      on public.sip_installments (user_id, created_at desc);

    -- The engine reads a SIP's whole ledger by parent on every refresh.
    create index idx_sip_installments_parent
      on public.sip_installments (user_id, (data ->> 'parent_id'));

    alter table public.sip_installments enable row level security;

    create policy sip_installments_select_own on public.sip_installments
      for select using (user_id = auth.uid());
    create policy sip_installments_insert_own on public.sip_installments
      for insert with check (user_id = auth.uid());
    create policy sip_installments_update_own on public.sip_installments
      for update using (user_id = auth.uid()) with check (user_id = auth.uid());
    create policy sip_installments_delete_own on public.sip_installments
      for delete using (user_id = auth.uid());
  end if;
end;
$$;

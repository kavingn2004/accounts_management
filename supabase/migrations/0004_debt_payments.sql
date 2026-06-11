-- =============================================================================
-- 0004 — debt_payments  (per-person installment ledger for debtors/creditors)
-- =============================================================================
-- Adds one more JSONB-backed app "table", matching the model in schema.sql.
-- The app logs each partial payment here (parent_id = source row id,
-- parent_type = 'debtors'/'creditors', amount, account, date) so a debt can be
-- settled part by part and its payment history shown.
--
-- Safe to run on an existing project: creates the table + owner-only RLS only
-- if it isn't already present.
-- =============================================================================

create extension if not exists pgcrypto;

do $$
begin
  if not exists (
    select 1 from pg_tables
    where schemaname = 'public' and tablename = 'debt_payments'
  ) then
    create table public.debt_payments (
      id         uuid        primary key default gen_random_uuid(),
      user_id    uuid        not null default auth.uid()
                             references auth.users (id) on delete cascade,
      data       jsonb       not null default '{}'::jsonb,
      created_at timestamptz not null default now()
    );

    create index idx_debt_payments_user
      on public.debt_payments (user_id, created_at desc);

    alter table public.debt_payments enable row level security;

    create policy debt_payments_select_own on public.debt_payments
      for select using (user_id = auth.uid());
    create policy debt_payments_insert_own on public.debt_payments
      for insert with check (user_id = auth.uid());
    create policy debt_payments_update_own on public.debt_payments
      for update using (user_id = auth.uid()) with check (user_id = auth.uid());
    create policy debt_payments_delete_own on public.debt_payments
      for delete using (user_id = auth.uid());
  end if;
end;
$$;

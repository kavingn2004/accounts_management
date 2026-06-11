-- =============================================================================
-- Accounflow — Supabase schema (run this whole file in the SQL Editor)
-- =============================================================================
-- This schema MIRRORS the app's on-device data model exactly, so the existing
-- Flutter logic (balance + dashboard computation) keeps working unchanged.
--
-- Each "table" the app uses is stored as one row per record with the record's
-- fields kept in a JSONB `data` column. Every row is owned by a user (user_id ->
-- auth.users) and protected by Row Level Security, so a signed-in user can only
-- ever read/write their own rows. The app authenticates with Supabase email +
-- password; the on-device PIN stays as a second lock on top.
--
-- NOTE: the older relational migrations in supabase/migrations/ used a DIFFERENT
-- model (account_id FKs, separate payment tables, no transfers/cash_moves) that
-- does not match how the app actually stores data. This file replaces them.
-- Running it will DROP those tables if present — only do so on an empty project.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Clean up objects from the older relational migrations (safe if they don't
-- exist). Drops in dependency order; CASCADE removes their policies/triggers.
-- -----------------------------------------------------------------------------
drop view if exists public.v_dashboard       cascade;
drop view if exists public.v_net_worth       cascade;
drop view if exists public.v_monthly_summary cascade;

drop table if exists public.bill_payments  cascade;
drop table if exists public.debt_payments  cascade;
drop table if exists public.savings_txns   cascade;
drop table if exists public.categories     cascade;
drop table if exists public.profiles       cascade;

-- App tables (dropped so this file can be re-run cleanly during setup).
drop table if exists public.accounts       cascade;
drop table if exists public.income         cascade;
drop table if exists public.expenses       cascade;
drop table if exists public.savings_goals  cascade;
drop table if exists public.investments    cascade;
drop table if exists public.debtors        cascade;
drop table if exists public.creditors      cascade;
drop table if exists public.bills          cascade;
drop table if exists public.loans          cascade;
drop table if exists public.transfers      cascade;
drop table if exists public.cash_moves     cascade;
drop table if exists public.alerts         cascade;

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user() cascade;

-- -----------------------------------------------------------------------------
-- Create one JSONB-backed table per app "table". A helper keeps it DRY.
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
  app_tables text[] := array[
    'accounts','income','expenses','savings_goals','investments',
    'debtors','creditors','bills','loans','transfers','cash_moves',
    'debt_payments','alerts'
  ];
begin
  foreach t in array app_tables loop
    execute format($f$
      create table public.%I (
        id         uuid        primary key default gen_random_uuid(),
        user_id    uuid        not null default auth.uid()
                               references auth.users (id) on delete cascade,
        data       jsonb       not null default '{}'::jsonb,
        created_at timestamptz not null default now()
      );
    $f$, t);

    execute format(
      'create index %I on public.%I (user_id, created_at desc);',
      'idx_' || t || '_user', t);

    execute format('alter table public.%I enable row level security;', t);

    -- Owner-only policies (select / insert / update / delete).
    execute format(
      'create policy %I on public.%I for select using (user_id = auth.uid());',
      t || '_select_own', t);
    execute format(
      'create policy %I on public.%I for insert with check (user_id = auth.uid());',
      t || '_insert_own', t);
    execute format(
      'create policy %I on public.%I for update using (user_id = auth.uid()) with check (user_id = auth.uid());',
      t || '_update_own', t);
    execute format(
      'create policy %I on public.%I for delete using (user_id = auth.uid());',
      t || '_delete_own', t);
  end loop;
end;
$$;

-- =============================================================================
-- Done. The app reads/writes these tables via the Supabase client; all balance
-- and net-worth math is computed in the app from these rows.
-- =============================================================================

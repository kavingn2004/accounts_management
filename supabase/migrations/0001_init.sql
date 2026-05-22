-- =============================================================================
-- Accounts Management App — Initial Schema
-- Stack: Flutter + Supabase (Postgres)
-- Auth model: Email signup (Supabase Auth) + on-device numeric PIN lock
-- Currency: single currency per user (stored on profile)
--
-- Every table is owned by a user (user_id -> auth.users) and protected by
-- Row Level Security so a user can only ever read/write their own rows.
-- Run this in the Supabase SQL editor (or via `supabase db push`).
-- =============================================================================

-- Needed for gen_random_uuid()
create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Helper: keep updated_at fresh on UPDATE
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =============================================================================
-- profiles  (1 row per auth user)
-- pin_hash holds the *hashed* PIN. Never store the raw PIN.
-- =============================================================================
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text,
  currency    text        not null default 'INR',
  pin_hash    text,                          -- set after first PIN setup
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger trg_profiles_updated
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-create a profile row whenever a new auth user signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name)
  values (new.id, new.raw_user_meta_data ->> 'name');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =============================================================================
-- accounts  (wallets / bank / cash buckets money lives in)
-- =============================================================================
create table public.accounts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  name        text        not null,
  type        text        not null default 'cash'
                          check (type in ('cash','bank','wallet','card')),
  balance     numeric(14,2) not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index idx_accounts_user on public.accounts (user_id);
create trigger trg_accounts_updated before update on public.accounts
  for each row execute function public.set_updated_at();

-- =============================================================================
-- categories  (shared by income & expenses, distinguished by `kind`)
-- =============================================================================
create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  name        text        not null,
  kind        text        not null check (kind in ('income','expense')),
  icon        text,
  created_at  timestamptz not null default now()
);
create index idx_categories_user on public.categories (user_id);

-- =============================================================================
-- income
-- =============================================================================
create table public.income (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  account_id  uuid        references public.accounts (id) on delete set null,
  category_id uuid        references public.categories (id) on delete set null,
  amount      numeric(14,2) not null check (amount >= 0),
  source      text,
  note        text,
  date        date        not null default current_date,
  created_at  timestamptz not null default now()
);
create index idx_income_user_date on public.income (user_id, date desc);

-- =============================================================================
-- expenses
-- =============================================================================
create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  account_id  uuid        references public.accounts (id) on delete set null,
  category_id uuid        references public.categories (id) on delete set null,
  amount      numeric(14,2) not null check (amount >= 0),
  payee       text,
  note        text,
  date        date        not null default current_date,
  created_at  timestamptz not null default now()
);
create index idx_expenses_user_date on public.expenses (user_id, date desc);

-- =============================================================================
-- savings — goals + contributions
-- =============================================================================
create table public.savings_goals (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid        not null references auth.users (id) on delete cascade,
  name          text        not null,
  target_amount numeric(14,2) not null check (target_amount >= 0),
  saved_amount  numeric(14,2) not null default 0,
  target_date   date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index idx_savings_goals_user on public.savings_goals (user_id);
create trigger trg_savings_goals_updated before update on public.savings_goals
  for each row execute function public.set_updated_at();

create table public.savings_txns (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  goal_id     uuid        not null references public.savings_goals (id) on delete cascade,
  amount      numeric(14,2) not null,
  date        date        not null default current_date,
  created_at  timestamptz not null default now()
);
create index idx_savings_txns_goal on public.savings_txns (goal_id);

-- =============================================================================
-- investments
-- =============================================================================
create table public.investments (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users (id) on delete cascade,
  name            text        not null,
  type            text        not null default 'stock'
                              check (type in ('stock','fund','fd','crypto','gold','other')),
  invested_amount numeric(14,2) not null default 0,
  current_value   numeric(14,2) not null default 0,
  units           numeric(18,6),
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_investments_user on public.investments (user_id);
create trigger trg_investments_updated before update on public.investments
  for each row execute function public.set_updated_at();

-- =============================================================================
-- debtors  (people who owe YOU)  &  creditors (people YOU owe)
-- Both share the same shape; debt_payments references either via parent_type.
-- =============================================================================
create table public.debtors (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  person_name text        not null,
  contact     text,
  amount      numeric(14,2) not null check (amount >= 0),
  due_date    date,
  status      text        not null default 'open'
                          check (status in ('open','partial','settled')),
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index idx_debtors_user on public.debtors (user_id);
create trigger trg_debtors_updated before update on public.debtors
  for each row execute function public.set_updated_at();

create table public.creditors (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  person_name text        not null,
  contact     text,
  amount      numeric(14,2) not null check (amount >= 0),
  due_date    date,
  status      text        not null default 'open'
                          check (status in ('open','partial','settled')),
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index idx_creditors_user on public.creditors (user_id);
create trigger trg_creditors_updated before update on public.creditors
  for each row execute function public.set_updated_at();

create table public.debt_payments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  parent_id   uuid        not null,
  parent_type text        not null check (parent_type in ('debtor','creditor')),
  amount      numeric(14,2) not null check (amount >= 0),
  date        date        not null default current_date,
  note        text,
  created_at  timestamptz not null default now()
);
create index idx_debt_payments_parent on public.debt_payments (parent_id, parent_type);

-- =============================================================================
-- bills + bill payments
-- =============================================================================
create table public.bills (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  name        text        not null,
  amount      numeric(14,2) not null check (amount >= 0),
  due_day     int         check (due_day between 1 and 31),  -- day of month
  frequency   text        not null default 'monthly'
                          check (frequency in ('weekly','monthly','quarterly','yearly')),
  category_id uuid        references public.categories (id) on delete set null,
  is_autopay  boolean     not null default false,
  status      text        not null default 'due'
                          check (status in ('due','paid','overdue')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index idx_bills_user on public.bills (user_id);
create trigger trg_bills_updated before update on public.bills
  for each row execute function public.set_updated_at();

create table public.bill_payments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  bill_id     uuid        not null references public.bills (id) on delete cascade,
  amount      numeric(14,2) not null check (amount >= 0),
  paid_date   date        not null default current_date,
  created_at  timestamptz not null default now()
);
create index idx_bill_payments_bill on public.bill_payments (bill_id);

-- =============================================================================
-- alerts  (bill due, debt due, goal milestone, budget overrun, ...)
-- =============================================================================
create table public.alerts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid        not null references auth.users (id) on delete cascade,
  type          text        not null,
  title         text        not null,
  message       text,
  related_id    uuid,                          -- optional FK-ish link to source row
  trigger_date  timestamptz,
  is_read       boolean     not null default false,
  created_at    timestamptz not null default now()
);
create index idx_alerts_user_unread on public.alerts (user_id, is_read);

-- =============================================================================
-- ROW LEVEL SECURITY
-- Enable RLS on every table, then add owner-only policies.
-- =============================================================================
alter table public.profiles       enable row level security;
alter table public.accounts       enable row level security;
alter table public.categories     enable row level security;
alter table public.income         enable row level security;
alter table public.expenses       enable row level security;
alter table public.savings_goals  enable row level security;
alter table public.savings_txns   enable row level security;
alter table public.investments    enable row level security;
alter table public.debtors        enable row level security;
alter table public.creditors      enable row level security;
alter table public.debt_payments  enable row level security;
alter table public.bills          enable row level security;
alter table public.bill_payments  enable row level security;
alter table public.alerts         enable row level security;

-- profiles: the row's primary key IS the user id
create policy "profiles_select_own" on public.profiles
  for select using (id = auth.uid());
create policy "profiles_update_own" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());
create policy "profiles_insert_own" on public.profiles
  for insert with check (id = auth.uid());

-- For all other tables: owner-only via user_id. Generate the four policies each.
do $$
declare
  t text;
  owned_tables text[] := array[
    'accounts','categories','income','expenses','savings_goals','savings_txns',
    'investments','debtors','creditors','debt_payments','bills','bill_payments','alerts'
  ];
begin
  foreach t in array owned_tables loop
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
-- Done. Next migration (0002) can add: balance-recompute triggers,
-- dashboard summary views, and a scheduled function to generate bill/debt alerts.
-- =============================================================================

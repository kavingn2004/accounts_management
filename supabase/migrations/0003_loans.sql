-- =============================================================================
-- 0003 — Loans module
-- A loan is money you borrowed (bank / person): principal, outstanding balance,
-- interest, EMI. Treated as a liability, so it reduces net worth.
-- =============================================================================

create table public.loans (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid        not null references auth.users (id) on delete cascade,
  lender        text        not null,
  principal     numeric(14,2) not null default 0 check (principal >= 0),
  outstanding   numeric(14,2) not null default 0 check (outstanding >= 0),
  interest_rate numeric(6,2),                       -- annual %
  emi           numeric(14,2),                      -- monthly payment
  start_date    date,
  status        text        not null default 'active'
                            check (status in ('active','closed')),
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index idx_loans_user on public.loans (user_id);
create trigger trg_loans_updated before update on public.loans
  for each row execute function public.set_updated_at();

-- RLS: owner-only
alter table public.loans enable row level security;
create policy "loans_select_own" on public.loans
  for select using (user_id = auth.uid());
create policy "loans_insert_own" on public.loans
  for insert with check (user_id = auth.uid());
create policy "loans_update_own" on public.loans
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "loans_delete_own" on public.loans
  for delete using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Fold outstanding loans into net worth (recreate the two dashboard views).
-- -----------------------------------------------------------------------------
create or replace view public.v_net_worth
with (security_invoker = true) as
select
  p.id as user_id,
  coalesce((select sum(balance)       from public.accounts    a where a.user_id = p.id), 0) as accounts_total,
  coalesce((select sum(current_value) from public.investments i where i.user_id = p.id), 0) as investments_total,
  coalesce((select sum(saved_amount)  from public.savings_goals s where s.user_id = p.id), 0) as savings_total,
  coalesce((select sum(d.amount) - coalesce(sum(dp.paid), 0)
            from public.debtors d
            left join (select parent_id, sum(amount) paid from public.debt_payments
                       where parent_type = 'debtor' group by parent_id) dp
              on dp.parent_id = d.id
            where d.user_id = p.id and d.status <> 'settled'), 0) as receivable_total,
  coalesce((select sum(c.amount) - coalesce(sum(cp.paid), 0)
            from public.creditors c
            left join (select parent_id, sum(amount) paid from public.debt_payments
                       where parent_type = 'creditor' group by parent_id) cp
              on cp.parent_id = c.id
            where c.user_id = p.id and c.status <> 'settled'), 0) as payable_total,
  coalesce((select sum(outstanding) from public.loans l
            where l.user_id = p.id and l.status = 'active'), 0) as loans_total
from public.profiles p;

create or replace view public.v_dashboard
with (security_invoker = true) as
select
  nw.user_id,
  nw.accounts_total,
  nw.investments_total,
  nw.savings_total,
  nw.receivable_total,
  nw.payable_total,
  nw.loans_total,
  (nw.accounts_total + nw.investments_total + nw.savings_total
     + nw.receivable_total - nw.payable_total - nw.loans_total) as net_worth,
  coalesce(ms.total_income,  0) as month_income,
  coalesce(ms.total_expense, 0) as month_expense,
  coalesce(ms.net,           0) as month_net
from public.v_net_worth nw
left join public.v_monthly_summary ms
  on ms.user_id = nw.user_id
 and ms.month   = date_trunc('month', current_date)::date;

-- =============================================================================
-- 0002 — Auto-recompute triggers + dashboard views
--
-- Triggers keep derived numbers correct without trusting the client:
--   * accounts.balance        = opening_balance + income - expenses
--   * savings_goals.saved_amount = sum(savings_txns)
--   * debtors/creditors.status   = open | partial | settled (from payments)
--
-- Views power the dashboard. All views use security_invoker so the querying
-- user's RLS still applies (a user only ever sees their own aggregates).
-- =============================================================================

-- Opening balance lets an account start at a non-zero amount; the running
-- balance is then derived from transactions.
alter table public.accounts
  add column if not exists opening_balance numeric(14,2) not null default 0;

-- -----------------------------------------------------------------------------
-- Account balance
-- -----------------------------------------------------------------------------
create or replace function public.recompute_account_balance(acc uuid)
returns void language plpgsql as $$
begin
  if acc is null then return; end if;
  update public.accounts a
  set balance = a.opening_balance
    + coalesce((select sum(amount) from public.income   where account_id = acc), 0)
    - coalesce((select sum(amount) from public.expenses where account_id = acc), 0)
  where a.id = acc;
end;
$$;

-- One trigger fn reused by both income and expenses (both have account_id).
create or replace function public.trg_tx_account_balance()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    perform public.recompute_account_balance(new.account_id);
  elsif tg_op = 'DELETE' then
    perform public.recompute_account_balance(old.account_id);
  else -- UPDATE
    perform public.recompute_account_balance(new.account_id);
    if old.account_id is distinct from new.account_id then
      perform public.recompute_account_balance(old.account_id);
    end if;
  end if;
  return null;
end;
$$;

create trigger trg_income_balance
  after insert or update or delete on public.income
  for each row execute function public.trg_tx_account_balance();

create trigger trg_expenses_balance
  after insert or update or delete on public.expenses
  for each row execute function public.trg_tx_account_balance();

-- Recompute when opening_balance itself changes.
create or replace function public.trg_account_opening()
returns trigger language plpgsql as $$
begin
  perform public.recompute_account_balance(new.id);
  return null;
end;
$$;

create trigger trg_account_opening_balance
  after update of opening_balance on public.accounts
  for each row when (old.opening_balance is distinct from new.opening_balance)
  execute function public.trg_account_opening();

-- -----------------------------------------------------------------------------
-- Savings goal saved_amount
-- -----------------------------------------------------------------------------
create or replace function public.recompute_savings_goal(g uuid)
returns void language plpgsql as $$
begin
  if g is null then return; end if;
  update public.savings_goals sg
  set saved_amount = coalesce(
        (select sum(amount) from public.savings_txns where goal_id = g), 0)
  where sg.id = g;
end;
$$;

create or replace function public.trg_savings_txn()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    perform public.recompute_savings_goal(old.goal_id);
  else
    perform public.recompute_savings_goal(new.goal_id);
    if tg_op = 'UPDATE' and old.goal_id is distinct from new.goal_id then
      perform public.recompute_savings_goal(old.goal_id);
    end if;
  end if;
  return null;
end;
$$;

create trigger trg_savings_txn_amount
  after insert or update or delete on public.savings_txns
  for each row execute function public.trg_savings_txn();

-- -----------------------------------------------------------------------------
-- Debtor / creditor status from payments
-- -----------------------------------------------------------------------------
create or replace function public.recompute_debt_status(p_id uuid, p_type text)
returns void language plpgsql as $$
declare
  total      numeric(14,2);
  paid       numeric(14,2);
  new_status text;
begin
  if p_id is null then return; end if;

  paid := coalesce((select sum(amount) from public.debt_payments
                    where parent_id = p_id and parent_type = p_type), 0);

  if p_type = 'debtor' then
    select amount into total from public.debtors where id = p_id;
  else
    select amount into total from public.creditors where id = p_id;
  end if;
  if total is null then return; end if;

  if    paid <= 0      then new_status := 'open';
  elsif paid < total   then new_status := 'partial';
  else                      new_status := 'settled';
  end if;

  if p_type = 'debtor' then
    update public.debtors   set status = new_status where id = p_id and status is distinct from new_status;
  else
    update public.creditors set status = new_status where id = p_id and status is distinct from new_status;
  end if;
end;
$$;

create or replace function public.trg_debt_payment()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    perform public.recompute_debt_status(old.parent_id, old.parent_type);
  else
    perform public.recompute_debt_status(new.parent_id, new.parent_type);
    if tg_op = 'UPDATE'
       and (old.parent_id   is distinct from new.parent_id
         or old.parent_type is distinct from new.parent_type) then
      perform public.recompute_debt_status(old.parent_id, old.parent_type);
    end if;
  end if;
  return null;
end;
$$;

create trigger trg_debt_payment_status
  after insert or update or delete on public.debt_payments
  for each row execute function public.trg_debt_payment();

-- Re-evaluate status if the original owed amount is edited.
-- (guarded with WHEN so the status UPDATE inside doesn't recurse)
create or replace function public.trg_debt_parent_amount()
returns trigger language plpgsql as $$
begin
  perform public.recompute_debt_status(new.id, tg_argv[0]);
  return null;
end;
$$;

create trigger trg_debtor_amount
  after update of amount on public.debtors
  for each row when (old.amount is distinct from new.amount)
  execute function public.trg_debt_parent_amount('debtor');

create trigger trg_creditor_amount
  after update of amount on public.creditors
  for each row when (old.amount is distinct from new.amount)
  execute function public.trg_debt_parent_amount('creditor');

-- =============================================================================
-- DASHBOARD VIEWS  (security_invoker => respect each user's RLS)
-- =============================================================================

-- Monthly income vs expense vs net, one row per (user, month).
create or replace view public.v_monthly_summary
with (security_invoker = true) as
with tx as (
  select user_id, date, amount, 'income'  as kind from public.income
  union all
  select user_id, date, amount, 'expense' as kind from public.expenses
)
select
  user_id,
  date_trunc('month', date)::date as month,
  coalesce(sum(amount) filter (where kind = 'income'),  0) as total_income,
  coalesce(sum(amount) filter (where kind = 'expense'), 0) as total_expense,
  coalesce(sum(amount) filter (where kind = 'income'),  0)
    - coalesce(sum(amount) filter (where kind = 'expense'), 0) as net
from tx
group by user_id, date_trunc('month', date);

-- Net-worth components + computed total, one row per user.
-- Receivable/payable use outstanding (owed amount minus payments recorded).
create or replace view public.v_net_worth
with (security_invoker = true) as
select
  p.id as user_id,
  coalesce((select sum(balance)        from public.accounts    a where a.user_id = p.id), 0) as accounts_total,
  coalesce((select sum(current_value)  from public.investments i where i.user_id = p.id), 0) as investments_total,
  coalesce((select sum(saved_amount)   from public.savings_goals s where s.user_id = p.id), 0) as savings_total,
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
            where c.user_id = p.id and c.status <> 'settled'), 0) as payable_total
from public.profiles p;

-- Convenience: single-row dashboard snapshot for the current month.
create or replace view public.v_dashboard
with (security_invoker = true) as
select
  nw.user_id,
  nw.accounts_total,
  nw.investments_total,
  nw.savings_total,
  nw.receivable_total,
  nw.payable_total,
  (nw.accounts_total + nw.investments_total + nw.savings_total
     + nw.receivable_total - nw.payable_total) as net_worth,
  coalesce(ms.total_income,  0) as month_income,
  coalesce(ms.total_expense, 0) as month_expense,
  coalesce(ms.net,           0) as month_net
from public.v_net_worth nw
left join public.v_monthly_summary ms
  on ms.user_id = nw.user_id
 and ms.month   = date_trunc('month', current_date)::date;

-- =============================================================================
-- Done. A later 0003 can add an Edge Function + cron to populate `alerts`
-- for bills/debts coming due.
-- =============================================================================

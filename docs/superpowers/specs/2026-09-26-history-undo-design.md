# History tab with Undo, and newest-first income/expenses

Date: 2026-09-26

## What the user gets

- A **History** item in the drawer listing the last **30** actions (adds,
  edits, deletes, payments, settlements, SIP changes, accounts, alerts),
  newest first.
- Each entry has **Undo**, which reverses every row that action wrote: an add
  is deleted, an edit goes back to the old values, a delete comes back with its
  original id and position.
- **Income, Expenses and Transfers** lists sort by entry `date`, latest first;
  same-day rows show the most recently added first; rows with no date go last.

## Design

- `HistoryRepository` (lib/data/history.dart) wraps the real repository in
  `repoProvider`. Writes made inside `recordAction(...)` / `action(...)` are
  captured (the capture list travels with the action in a Dart `Zone`, so
  service code called from it is covered too) and saved as one `HistoryEntry`.
  Writes outside an action — SIP engine, price sync — are never recorded.
- Snapshots: insert → new row; update → row before and after; delete → full
  row. Undo replays them in reverse. Undoing an insert also deletes rows that
  point at it by `parent_id` in `module_events`, `sip_installments`,
  `debt_payments` (e.g. the opening ledger event written after the sheet).
- Undo needs two extra writes, `insertReturningId` and `restore`, in a separate
  `UndoableRepository` interface implemented by the local and Supabase repos.
  Fakes that only implement `FinanceRepository` still work; nothing is recorded
  for them.
- **Conflict rule:** an entry can't be undone while a newer, not-undone entry
  touched the same row (or added a child of a row this entry created). The UI
  shows a disabled Undo with "Undo the newer change first".
- Storage: `LocalStore` key `history_log`, on-device only (also with cloud
  sync on), capped at 30. Factory reset clears it.
- Sorting: `sortRowsByDateDesc` applied in `EntityScreen._applyFilter` for any
  module with `orderBy: 'date'`. The repositories ignore `orderBy`, which is
  why back-dated entries used to appear at the top.

## Tests

- test/history_test.dart — recording, grouping, 30 cap, undo of
  insert/update/delete, child cleanup, conflict rule, reset.
- test/history_e2e_test.dart — real app: add expense → History → Undo; sort.
- test/widget_test.dart — delete targets the Salary row by name (it is no
  longer the top row under date sorting).

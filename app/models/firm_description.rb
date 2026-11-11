# frozen_string_literal: true

# Column-ACL pin: `ledger_runtime` holds `INSERT (uuid, name, opening_balance_cents)`
# and column-level `UPDATE (name)` ONLY (`CreateFinancialLedger`).
# `record_timestamps = false` prevents ActiveRecord from injecting `created_at` / `updated_at`
# into `INSERT` or `UPDATE` SQL, which PostgreSQL would reject with `42501 insufficient_privilege`;
# column defaults and `guard_firm_descriptions_immutability()` maintain timestamps inside PG.
class FirmDescription < ApplicationRecord
  self.table_name = "firm_descriptions"
  self.record_timestamps = false

  attr_readonly :id, :uuid, :opening_balance_cents, :created_at
end

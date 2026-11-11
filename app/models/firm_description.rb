# frozen_string_literal: true

# Represents the `public.firm_descriptions` metadata table.
#
# Runtime role (`ledger_runtime`) permissions:
# - INSERT (uuid, name, opening_balance_cents)
# - UPDATE (name) only
# - SELECT (id, uuid, name, opening_balance_cents, created_at, updated_at)
#
# Timestamps are managed strictly by PostgreSQL defaults and triggers so
# column-level UPDATE(name) remains enforced at the database layer.
class FirmDescription < ApplicationRecord
  self.table_name = "firm_descriptions"
  self.record_timestamps = false

  attr_readonly :id, :uuid, :opening_balance_cents, :created_at
end

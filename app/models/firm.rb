# frozen_string_literal: true

# Read-only model backed by the `public.firms` database view, which derives
# exact NUMERIC `balance_cents` from `firm_descriptions.opening_balance_cents`
# and the `payments` ledger without stored cumulative snapshots.
class Firm < ApplicationRecord
  self.table_name = "firms"
  self.primary_key = "id"

  def readonly?
    true
  end
end

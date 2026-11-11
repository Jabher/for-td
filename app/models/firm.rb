# frozen_string_literal: true

# Backed by the read-only `public.firms` SQL view (`balance_cents` is exact `NUMERIC`,
# derived live from `opening_balance_cents + incoming - outgoing` with zero stored snapshots).
class Firm < ApplicationRecord
  self.table_name = "firms"
  self.primary_key = "id"

  def readonly?
    true
  end
end

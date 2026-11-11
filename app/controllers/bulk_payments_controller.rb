# frozen_string_literal: true

# Sole HTTP endpoint (`POST /bulk_payments`).
#
# Guard pipeline:
# 1. `BulkPayments::PayloadParser` enforces stateless boundary invariants in memory
#    so bad requests never lease a database connection or touch PostgreSQL.
# 2. `BulkPayments::Poster` opens a top-level `READ COMMITTED` transaction and invokes
#    `public.post_bulk_payments`, where PostgreSQL enforces stateful accounting invariants
#    and independent database safeguards.
#
# Out-of-scope pin: HTTP `Idempotency-Key` is intentionally not implemented; repeated
# requests or identical items within a batch persist as distinct transfers.
class BulkPaymentsController < ApplicationController
  def create
    parsed_batch = BulkPayments::PayloadParser.parse(request.raw_post)
    result = BulkPayments::Poster.call(parsed_batch)

    render json: result, status: :created
  end
end

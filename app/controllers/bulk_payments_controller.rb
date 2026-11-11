# frozen_string_literal: true

class BulkPaymentsController < ApplicationController
  # POST /bulk_payments
  #
  # Note: HTTP Idempotency-Key support is intentionally out of scope.
  # Repeated requests or repeated payment items within a batch are treated as
  # distinct transfers and persisted atomically if the payer can cover the full batch.
  def create
    parsed_batch = BulkPayments::PayloadParser.parse(request.raw_post)
    result = BulkPayments::Poster.call(parsed_batch)

    render json: result, status: :created
  end
end

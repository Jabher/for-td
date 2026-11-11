# frozen_string_literal: true

module BulkPayments
  # Structured domain error implementing the "errors-as-doors" pattern:
  # every error carries a stable `code`, `what` went wrong, `why` it was rejected,
  # and `how_to_fix` it, plus optional `field` / `payment_index` pointers.
  class Error < StandardError
    attr_reader :code, :what, :why, :how_to_fix, :field, :payment_index

    def initialize(code:, what:, why:, how_to_fix:, field: nil, payment_index: nil)
      @code = code.to_s
      @what = what.to_s
      @why = why.to_s
      @how_to_fix = how_to_fix.to_s
      @field = field&.to_s
      @payment_index = payment_index
      super(@what)
    end

    def to_payload
      error_hash = {
        code: @code,
        what: @what,
        why: @why,
        how_to_fix: @how_to_fix
      }
      error_hash[:field] = @field unless @field.nil?
      error_hash[:payment_index] = @payment_index unless @payment_index.nil?

      { error: error_hash }
    end
  end
end

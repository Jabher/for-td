# frozen_string_literal: true

# Boundary rejection contract (`errors-as-doors` pattern; see `skills/errors-as-doors/SKILL.md`).
# Rescued by `ApplicationController#render_domain_error` as HTTP 422 JSON (`fact -> reason -> action`).
# Never used for unhandled internal faults, which fall through to a generic HTTP 500 response.
module BulkPayments
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

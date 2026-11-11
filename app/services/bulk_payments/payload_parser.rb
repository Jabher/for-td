# frozen_string_literal: true

module BulkPayments
  # Layer 1 — Service Shortcut Guard (Zero-DB Boundary).
  #
  # Enforces every stateless HTTP/JSON invariant in memory (UTF-8 & RFC 8259 JSON syntax,
  # strict object shape, 1..1000 batch bounds, UUID syntax, exact USD string-to-int4-cent
  # conversion without floats, non-blank descriptions, and payer != payee self-payment
  # rejection) as an early shortcut so malformed or invalid requests never lease a
  # connection, acquire locks, or touch PostgreSQL.
  #
  # PostgreSQL mirrors these invariants independently as Layer 2 safeguards inside
  # `public.post_bulk_payments`, table constraints, triggers, and role ACLs
  # (see `CreateFinancialLedger` and `BulkPayments::Poster`).
  class PayloadParser
    UUID_PATTERN = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
    USD_AMOUNT_PATTERN = /\A(?:0|[1-9][0-9]*)(?:\.[0-9]{1,2})?\z/
    MAX_PG_INT4_CENTS = 2_147_483_647
    MIN_BATCH_SIZE = 1
    MAX_BATCH_SIZE = 1_000
    ALLOWED_ROOT_KEYS = %w[payer_firm_uuid payments].freeze
    ALLOWED_PAYMENT_KEYS = %w[amount payee_firm_uuid description].freeze

    ParsedBatch = Data.define(:payer_firm_uuid, :payee_firm_uuids, :amounts_cents, :descriptions)

    class << self
      def parse(raw_body)
        payload = decode_json(raw_body)
        validate_root_object!(payload)

        payer_uuid = parse_uuid!(payload["payer_firm_uuid"], field: "payer_firm_uuid")
        raw_payments = validate_payments_array!(payload["payments"])

        payee_uuids = Array.new(raw_payments.size)
        amounts_cents = Array.new(raw_payments.size)
        descriptions = Array.new(raw_payments.size)

        raw_payments.each_with_index do |item, index|
          validate_payment_object!(item, index)

          payee_uuid = parse_uuid!(
            item["payee_firm_uuid"],
            field: "payments[#{index}].payee_firm_uuid",
            payment_index: index
          )
          reject_self_payment!(payer_uuid, payee_uuid, index)

          payee_uuids[index] = payee_uuid
          amounts_cents[index] = parse_amount_cents!(item["amount"], index)
          descriptions[index] = parse_description!(item["description"], index)
        end

        ParsedBatch.new(
          payer_firm_uuid: payer_uuid,
          payee_firm_uuids: payee_uuids,
          amounts_cents: amounts_cents,
          descriptions: descriptions
        )
      end

      private

        def decode_json(raw_body)
          body_str = raw_body.to_s
          if body_str.bytesize.zero? || body_str.strip.empty?
            raise Error.new(
              code: "malformed_json",
              what: "Request body is empty instead of a valid JSON object.",
              why: "POST /bulk_payments requires a JSON object containing payer_firm_uuid and payments.",
              how_to_fix: "Send a non-empty UTF-8 JSON object body with Content-Type: application/json."
            )
          end

          unless body_str.encoding == Encoding::UTF_8 || body_str.dup.force_encoding(Encoding::UTF_8).valid_encoding?
            raise Error.new(
              code: "malformed_json",
              what: "Request body contains invalid UTF-8 byte sequences.",
              why: "JSON payloads must be valid UTF-8 text.",
              how_to_fix: "Encode the request body as valid UTF-8 JSON."
            )
          end

          utf8_body = body_str.encoding == Encoding::UTF_8 ? body_str : body_str.dup.force_encoding(Encoding::UTF_8)
          JSON.parse(utf8_body, max_nesting: 10)
        rescue JSON::ParserError => e
          detail = e.message.lines.first.to_s.strip
          raise Error.new(
            code: "malformed_json",
            what: "Malformed JSON in request body: #{detail}",
            why: "The request body could not be parsed according to RFC 8259 JSON syntax rules.",
            how_to_fix: "Fix the JSON syntax error (check quotes, commas, brackets, and trailing characters) and resubmit."
          )
        end

        def validate_root_object!(payload)
          unless payload.is_a?(Hash)
            raise Error.new(
              code: "invalid_payload_shape",
              what: "Top-level JSON value must be an object, got #{json_type_name(payload)}.",
              why: "POST /bulk_payments accepts only a JSON object with keys payer_firm_uuid and payments.",
              how_to_fix: "Wrap the request payload in a JSON object containing \"payer_firm_uuid\" and \"payments\"."
            )
          end

          unknown_keys = payload.keys - ALLOWED_ROOT_KEYS
          if unknown_keys.any?
            raise Error.new(
              code: "unexpected_fields",
              what: "Unexpected top-level field(s): #{unknown_keys.sort.join(', ')}.",
              why: "Only \"payer_firm_uuid\" and \"payments\" are permitted at the top level.",
              how_to_fix: "Remove unexpected top-level keys so only \"payer_firm_uuid\" and \"payments\" remain.",
              field: unknown_keys.sort.first
            )
          end

          missing_keys = ALLOWED_ROOT_KEYS - payload.keys
          if missing_keys.any?
            raise Error.new(
              code: "missing_required_field",
              what: "Missing required top-level field(s): #{missing_keys.join(', ')}.",
              why: "Both \"payer_firm_uuid\" and \"payments\" are mandatory.",
              how_to_fix: "Include #{missing_keys.map { |k| "\"#{k}\"" }.join(' and ')} in the top-level JSON object.",
              field: missing_keys.first
            )
          end
        end

        def validate_payments_array!(payments)
          unless payments.is_a?(Array)
            raise Error.new(
              code: "invalid_payments_type",
              what: "\"payments\" must be a JSON array, got #{json_type_name(payments)}.",
              why: "Bulk payments are submitted as an ordered list of payment objects.",
              how_to_fix: "Provide \"payments\" as a JSON array of 1 to #{MAX_BATCH_SIZE} payment objects.",
              field: "payments"
            )
          end

          if payments.size < MIN_BATCH_SIZE || payments.size > MAX_BATCH_SIZE
            raise Error.new(
              code: "invalid_batch_size",
              what: "\"payments\" contains #{payments.size} item(s), outside the allowed range of #{MIN_BATCH_SIZE}..#{MAX_BATCH_SIZE}.",
              why: "Batches must contain at least #{MIN_BATCH_SIZE} payment and at most #{MAX_BATCH_SIZE} payments.",
              how_to_fix: payments.empty? ? "Include at least 1 payment object in \"payments\"." : "Split the request into batches of at most #{MAX_BATCH_SIZE} payments.",
              field: "payments"
            )
          end

          payments
        end

        def validate_payment_object!(item, index)
          unless item.is_a?(Hash)
            raise Error.new(
              code: "invalid_payment_item",
              what: "Payment at index #{index} must be a JSON object, got #{json_type_name(item)}.",
              why: "Each element of \"payments\" must be an object with \"amount\", \"payee_firm_uuid\", and \"description\".",
              how_to_fix: "Replace payments[#{index}] with a JSON object containing \"amount\", \"payee_firm_uuid\", and \"description\".",
              field: "payments[#{index}]",
              payment_index: index
            )
          end

          unknown_keys = item.keys - ALLOWED_PAYMENT_KEYS
          if unknown_keys.any?
            first_key = unknown_keys.sort.first
            raise Error.new(
              code: "unexpected_fields",
              what: "Unexpected field(s) in payments[#{index}]: #{unknown_keys.sort.join(', ')}.",
              why: "Payment objects accept only \"amount\", \"payee_firm_uuid\", and \"description\".",
              how_to_fix: "Remove unexpected keys from payments[#{index}].",
              field: "payments[#{index}].#{first_key}",
              payment_index: index
            )
          end

          missing_keys = ALLOWED_PAYMENT_KEYS - item.keys
          if missing_keys.any?
            first_key = missing_keys.first
            raise Error.new(
              code: "missing_required_field",
              what: "Missing required field(s) in payments[#{index}]: #{missing_keys.join(', ')}.",
              why: "Every payment requires \"amount\", \"payee_firm_uuid\", and \"description\".",
              how_to_fix: "Add #{missing_keys.map { |k| "\"#{k}\"" }.join(', ')} to payments[#{index}].",
              field: "payments[#{index}].#{first_key}",
              payment_index: index
            )
          end
        end

        def parse_uuid!(value, field:, payment_index: nil)
          unless value.is_a?(String) && UUID_PATTERN.match?(value)
            raise Error.new(
              code: "invalid_uuid",
              what: "\"#{field}\" must be a canonical 36-character UUID string.",
              why: value.is_a?(String) ? "The string #{value.inspect} is not a valid 8-4-4-4-12 hexadecimal UUID." : "Expected a JSON string UUID, got #{json_type_name(value)}.",
              how_to_fix: "Provide a valid UUID string (e.g. \"3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41\") for \"#{field}\".",
              field: field,
              payment_index: payment_index
            )
          end

          value.downcase
        end

        def reject_self_payment!(payer_uuid, payee_uuid, index)
          return unless payee_uuid == payer_uuid

          raise Error.new(
            code: "self_payment",
            what: "Self-payment is not permitted (payment at index #{index} targets payer firm #{payer_uuid}).",
            why: "A firm cannot transfer funds to itself; payer_firm_uuid and payee_firm_uuid must refer to distinct firms.",
            how_to_fix: "Ensure payments[#{index}].payee_firm_uuid differs from payer_firm_uuid.",
            field: "payments[#{index}].payee_firm_uuid",
            payment_index: index
          )
        end

        def parse_amount_cents!(value, index)
          field = "payments[#{index}].amount"

          unless value.is_a?(String)
            raise Error.new(
              code: "invalid_amount_type",
              what: "\"#{field}\" must be a JSON string representing US dollars, got #{json_type_name(value)}.",
              why: "Monetary amounts must be passed as decimal strings to avoid binary floating-point precision loss.",
              how_to_fix: "Pass \"#{field}\" as a JSON string such as \"1200.75\" or \"6250\".",
              field: field,
              payment_index: index
            )
          end

          unless USD_AMOUNT_PATTERN.match?(value)
            raise Error.new(
              code: "invalid_amount_format",
              what: "\"#{field}\" (#{value.inspect}) is not a valid US dollar decimal string.",
              why: "Amounts must contain ordinary ASCII digits with no leading zeros on the whole-dollar part, no signs, no whitespace, no exponent notation, and 0, 1, or 2 fractional digits.",
              how_to_fix: "Format \"#{field}\" as a positive decimal string like \"1\", \"1.2\", \"1.23\", or \"0.01\".",
              field: field,
              payment_index: index
            )
          end

          whole_str, frac_str = value.split(".", 2)
          padded_frac = (frac_str || "").ljust(2, "0")
          cents = (whole_str.to_i * 100) + padded_frac.to_i

          if cents <= 0
            raise Error.new(
              code: "non_positive_amount",
              what: "\"#{field}\" (#{value.inspect}) resolves to zero cents.",
              why: "Every payment amount must be strictly positive (at least $0.01).",
              how_to_fix: "Provide a non-zero US dollar amount of at least \"0.01\".",
              field: field,
              payment_index: index
            )
          end

          if cents > MAX_PG_INT4_CENTS
            raise Error.new(
              code: "amount_exceeds_limit",
              what: "\"#{field}\" (#{value.inspect}) exceeds the maximum single-payment limit of $21,474,836.47.",
              why: "Individual payment amounts are stored in PostgreSQL INTEGER (int4) and cannot exceed #{MAX_PG_INT4_CENTS} cents.",
              how_to_fix: "Ensure each individual payment amount is at most \"21474836.47\", splitting larger transfers across multiple payment items if needed.",
              field: field,
              payment_index: index
            )
          end

          cents
        end

        def parse_description!(value, index)
          field = "payments[#{index}].description"

          unless value.is_a?(String)
            raise Error.new(
              code: "invalid_description_type",
              what: "\"#{field}\" must be a JSON string, got #{json_type_name(value)}.",
              why: "Every payment requires a textual description.",
              how_to_fix: "Provide a non-empty JSON string for \"#{field}\".",
              field: field,
              payment_index: index
            )
          end

          if value.include?("\u0000")
            raise Error.new(
              code: "invalid_description",
              what: "\"#{field}\" contains a null byte (U+0000).",
              why: "PostgreSQL TEXT columns reject embedded null bytes.",
              how_to_fix: "Remove null bytes from \"#{field}\".",
              field: field,
              payment_index: index
            )
          end

          if value.gsub(/\A[\p{Space}\s]+|[\p{Space}\s]+\z/, "").empty?
            raise Error.new(
              code: "blank_description",
              what: "\"#{field}\" must not be empty or whitespace-only.",
              why: "Payment descriptions must remain non-empty after trimming surrounding whitespace.",
              how_to_fix: "Provide a meaningful non-blank description string for \"#{field}\".",
              field: field,
              payment_index: index
            )
          end

          value
        end

        def json_type_name(value)
          case value
          when NilClass then "null"
          when TrueClass, FalseClass then "boolean"
          when Integer, Float then "number"
          when String then "string"
          when Array then "array"
          when Hash then "object"
          else value.class.name
          end
        end
    end
  end
end

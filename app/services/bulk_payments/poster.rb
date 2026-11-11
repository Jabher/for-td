# frozen_string_literal: true

module BulkPayments
  # Transaction bridge to Layer 2 (`public.post_bulk_payments`; see `BulkPayments::PayloadParser`
  # for Layer 1 shortcut guards and `CreateFinancialLedger` for Layer 2 database safeguards).
  #
  # Zero accounting math or locking lives in Ruby:
  # - Opens a top-level `READ COMMITTED` transaction (`requires_new: false, joinable: false`
  #   because PostgreSQL rejects `ISOLATION LEVEL` inside a `SAVEPOINT` and the sender's
  #   `FOR NO KEY UPDATE` lock must be held until top-level commit/rollback).
  # - Passes bound typed arrays (`uuid[]`, `int4[]`, `text[]`) on a single connection.
  # - Translates PostgreSQL domain/safeguard exceptions (`DETAIL` / `MESSAGE` / `HINT`) into
  #   `BulkPayments::Error` doors, including safeguard codes also shortcut-checked in Layer 1
  #   when `Poster` is called directly outside HTTP parsing.
  class Poster
    POST_FUNCTION_SQL = <<~SQL.squish.freeze
      SELECT public.post_bulk_payments(
        $1::uuid,
        $2::uuid[],
        $3::int4[],
        $4::text[]
      ) AS payment_ids
    SQL

    KNOWN_PG_ERROR_CODES = {
      "insufficient_funds" => {
        code: "insufficient_funds",
        why: "The payer firm's current derived balance cannot cover the gross sum of all requested payments in this batch.",
        field: "payments"
      },
      "unknown_payer_firm" => {
        code: "unknown_payer_firm",
        why: "No firm exists with the provided payer_firm_uuid.",
        field: "payer_firm_uuid"
      },
      "unknown_payee_firm" => {
        code: "unknown_payee_firm",
        why: "Every payee_firm_uuid must identify an existing firm in firm_descriptions.",
        field: "payments"
      },
      "self_payment" => {
        code: "self_payment",
        why: "A firm cannot transfer funds to itself; payer_firm_uuid and payee_firm_uuid must refer to distinct firms.",
        field: "payments"
      },
      "invalid_batch_size" => {
        code: "invalid_batch_size",
        why: "Batches must contain between 1 and 1000 payment items.",
        field: "payments"
      },
      "invalid_amount_cents" => {
        code: "invalid_amount",
        why: "Each payment amount must be a positive integer cent value fitting PostgreSQL INTEGER.",
        field: "payments"
      },
      "blank_description" => {
        code: "blank_description",
        why: "Each payment description must be non-empty after trimming whitespace.",
        field: "payments"
      }
    }.freeze

    def self.call(parsed_batch)
      new(ApplicationRecord.lease_connection).call(parsed_batch)
    end

    def initialize(connection)
      @connection = connection
    end

    def call(parsed_batch)
      payment_ids = nil

      @connection.transaction(isolation: :read_committed, requires_new: false, joinable: false) do
        binds = build_binds(parsed_batch)
        result = @connection.exec_query(POST_FUNCTION_SQL, "BulkPayments::Post", binds, prepare: true)
        raw_ids = result.rows.dig(0, 0)
        payment_ids = decode_bigint_array(raw_ids)
      end

      {
        payer_firm_uuid: parsed_batch.payer_firm_uuid,
        payments_count: payment_ids.size,
        payment_ids: payment_ids
      }
    rescue ActiveRecord::StatementInvalid => e
      mapped_error = translate_pg_error(e)
      raise mapped_error if mapped_error

      raise
    end

    private

      def build_binds(parsed_batch)
        uuid_type = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Uuid.new
        uuid_array_type = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(uuid_type)
        int4_array_type = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(ActiveRecord::Type::Integer.new(limit: 4))
        text_array_type = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(ActiveRecord::Type::Text.new)

        [
          ActiveRecord::Relation::QueryAttribute.new("p_payer_uuid", parsed_batch.payer_firm_uuid, uuid_type),
          ActiveRecord::Relation::QueryAttribute.new("p_payee_uuids", parsed_batch.payee_firm_uuids, uuid_array_type),
          ActiveRecord::Relation::QueryAttribute.new("p_amounts_cents", parsed_batch.amounts_cents, int4_array_type),
          ActiveRecord::Relation::QueryAttribute.new("p_descriptions", parsed_batch.descriptions, text_array_type)
        ]
      end

      def decode_bigint_array(raw_value)
        return raw_value.map(&:to_i) if raw_value.is_a?(Array)

        bigint_array_type = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(ActiveRecord::Type::BigInteger.new)
        Array(bigint_array_type.deserialize(raw_value)).map(&:to_i)
      end

      def translate_pg_error(statement_invalid)
        pg_error = statement_invalid.cause
        return nil unless pg_error.is_a?(PG::Error) && pg_error.result

        detail = pg_error.result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)
        spec = KNOWN_PG_ERROR_CODES[detail]
        return nil unless spec

        primary = pg_error.result.error_field(PG::Result::PG_DIAG_MESSAGE_PRIMARY).to_s
        hint = pg_error.result.error_field(PG::Result::PG_DIAG_MESSAGE_HINT).to_s

        payment_index = extract_payment_index(primary)
        field = if payment_index && detail == "unknown_payee_firm"
          "payments[#{payment_index}].payee_firm_uuid"
        elsif payment_index && detail == "self_payment"
          "payments[#{payment_index}].payee_firm_uuid"
        else
          spec[:field]
        end

        Error.new(
          code: spec[:code],
          what: primary,
          why: spec[:why],
          how_to_fix: hint,
          field: field,
          payment_index: payment_index
        )
      end

      def extract_payment_index(message)
        match = message.match(/index (\d+)/)
        match ? match[1].to_i : nil
      end
  end
end

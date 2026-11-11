# frozen_string_literal: true

require "test_helper"

class BulkPaymentsIntegrationTest < ActionDispatch::IntegrationTest
  PAYER_UUID  = "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41"
  PAYEE1_UUID = "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25"
  PAYEE2_UUID = "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10"
  MISSING_UUID = "11111111-2222-4333-8444-555555555555"

  setup do
    @payer  = create_firm!(name: "Payer CPA LLC", opening_balance_cents: 2_000_000, uuid: PAYER_UUID)
    @payee1 = create_firm!(name: "Payee One Advisors", opening_balance_cents: 100_000, uuid: PAYEE1_UUID)
    @payee2 = create_firm!(name: "Payee Two Bookkeeping", opening_balance_cents: 0, uuid: PAYEE2_UUID)
  end

  # --- Positive Scenarios & Thresholds ---

  test "persists exact specification payload atomically and returns 201" do
    raw_json = <<~JSON
      {
        "payer_firm_uuid": "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
        "payments": [
          {
            "amount": "6250",
            "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
            "description": "Overflow returns, August 2026"
          },
          {
            "amount": "5800.5",
            "payee_firm_uuid": "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
            "description": "Amended returns, August 2026"
          },
          {
            "amount": "1200.75",
            "payee_firm_uuid": "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10",
            "description": "Bookkeeping cleanup, 3 clients"
          }
        ]
      }
    JSON

    post_raw(raw_json)
    assert_response :created

    body = JSON.parse(response.body)
    assert_equal PAYER_UUID, body["payer_firm_uuid"]
    assert_equal 3, body["payments_count"]
    assert_equal 3, body["payment_ids"].size

    # Gross sum: 625000 + 580050 + 120075 = 1,325,125 cents
    assert_equal 674_875, firm_balance_cents(PAYER_UUID)
    assert_equal 1_305_050, firm_balance_cents(PAYEE1_UUID)
    assert_equal 120_075, firm_balance_cents(PAYEE2_UUID)

    rows = fetch_all_payments
    assert_equal [ 625_000, 580_050, 120_075 ], rows.map { |r| r[:amount_cents] }
    assert_equal [
      "Overflow returns, August 2026",
      "Amended returns, August 2026",
      "Bookkeeping cleanup, 3 clients"
    ], rows.map { |r| r[:description] }
  end

  test "preserves fully identical transfers in the same batch as separate payment rows" do
    identical_item = {
      "amount" => "100.25",
      "payee_firm_uuid" => PAYEE1_UUID,
      "description" => "Duplicate retainer installment"
    }

    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [ identical_item, identical_item.dup, identical_item.dup ]
    )

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 3, body["payments_count"]
    assert_equal 3, body["payment_ids"].uniq.size

    rows = fetch_all_payments
    assert_equal 3, rows.size
    assert_equal [ 10_025, 10_025, 10_025 ], rows.map { |r| r[:amount_cents] }
    assert_equal [ 1_969_925, 130_075 ], [ firm_balance_cents(PAYER_UUID), firm_balance_cents(PAYEE1_UUID) ]
  end

  test "does not deduplicate on Idempotency-Key header (intentionally out of scope)" do
    payload = {
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "10.00", payee_firm_uuid: PAYEE1_UUID, description: "Non-idempotent transfer" } ]
    }

    post "/bulk_payments",
      params: JSON.generate(payload),
      headers: { "CONTENT_TYPE" => "application/json", "Idempotency-Key" => "same-key-123" }
    assert_response :created

    post "/bulk_payments",
      params: JSON.generate(payload),
      headers: { "CONTENT_TYPE" => "application/json", "Idempotency-Key" => "same-key-123" }
    assert_response :created

    assert_equal 2, fetch_all_payments.size
    assert_equal 1_998_000, firm_balance_cents(PAYER_UUID)
  end

  test "accepts all valid USD decimal formats without floating point drift" do
    # Include notorious binary float traps like 0.29, 19.99, 0.01, 0.50, 1, 1.2, 1.23, uppercase UUIDs
    amounts = [ "1", "1.2", "1.23", "0.01", "0.50", "0.29", "19.99", "9999.90" ]
    expected_cents = [ 100, 120, 123, 1, 50, 29, 1999, 999_990 ]

    post_json(
      payer_firm_uuid: PAYER_UUID.upcase,
      payments: amounts.map.with_index do |amt, idx|
        { amount: amt, payee_firm_uuid: PAYEE1_UUID.upcase, description: "Valid format #{idx} " }
      end
    )

    assert_response :created
    rows = fetch_all_payments
    assert_equal expected_cents, rows.map { |r| r[:amount_cents] }
    assert_equal "Valid format 0 ", rows.first[:description] # Preserves original description string
  end

  test "accepts exact single-payment PG INTEGER max (21474836.47) and batch total exceeding int4 max" do
    max_int4 = 2_147_483_647
    whale_payer = create_firm!(name: "Whale Sender", opening_balance_cents: max_int4)
    feeder1 = create_firm!(name: "Feeder 1", opening_balance_cents: max_int4)
    feeder2 = create_firm!(name: "Feeder 2", opening_balance_cents: max_int4)

    # Fund whale_payer so its derived NUMERIC balance is 3 * 2,147,483,647 = 6,442,450,941 cents (> int4 max)
    post_json(
      payer_firm_uuid: feeder1.uuid,
      payments: [ { amount: "21474836.47", payee_firm_uuid: whale_payer.uuid, description: "Top up 1" } ]
    )
    assert_response :created

    post_json(
      payer_firm_uuid: feeder2.uuid,
      payments: [ { amount: "21474836.47", payee_firm_uuid: whale_payer.uuid, description: "Top up 2" } ]
    )
    assert_response :created

    assert_equal 6_442_450_941, firm_balance_cents(whale_payer.uuid)

    # Whale sender now spends all 6,442,450,941 cents in a single batch of three 21474836.47 payments,
    # pushing PAYEE2's derived balance well beyond PostgreSQL INTEGER max (no recipient int4 cap).
    post_json(
      payer_firm_uuid: whale_payer.uuid,
      payments: Array.new(3) do |i|
        { amount: "21474836.47", payee_firm_uuid: PAYEE2_UUID, description: "Max int4 leg #{i}" }
      end
    )
    assert_response :created

    assert_equal 0, firm_balance_cents(whale_payer.uuid)
    assert_equal 6_442_450_941, firm_balance_cents(PAYEE2_UUID)
  end

  test "accepts batch boundary sizes of 1 and 1000 payments" do
    # Minimum batch size: 1
    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "0.01", payee_firm_uuid: PAYEE1_UUID, description: "Single item batch" } ]
    )
    assert_response :created
    assert_equal 1, JSON.parse(response.body)["payments_count"]

    # Maximum batch size: 1000
    thousand_items = Array.new(1_000) do |idx|
      {
        amount: "0.01",
        payee_firm_uuid: idx.even? ? PAYEE1_UUID : PAYEE2_UUID,
        description: "Batch item ##{idx} with 'quotes' and \\backslashes\\"
      }
    end

    post_json(payer_firm_uuid: PAYER_UUID, payments: thousand_items)
    assert_response :created
    assert_equal 1_000, JSON.parse(response.body)["payments_count"]
    assert_equal 1_001, fetch_all_payments.size
    assert_equal 2_000_000 - 1_001, firm_balance_cents(PAYER_UUID)
  end

  test "succeeds when payer balance exactly equals gross batch total (zero remaining balance)" do
    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [
        { amount: "10000.00", payee_firm_uuid: PAYEE1_UUID, description: "Half 1" },
        { amount: "10000", payee_firm_uuid: PAYEE2_UUID, description: "Half 2" }
      ]
    )
    assert_response :created
    assert_equal 0, firm_balance_cents(PAYER_UUID)
  end

  # --- Negative Scenarios & Off-By-One Thresholds ---

  test "rejects when payer balance is 1 cent below gross batch total and persists nothing" do
    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [
        { amount: "10000.00", payee_firm_uuid: PAYEE1_UUID, description: "First leg fits alone" },
        { amount: "10000.01", payee_firm_uuid: PAYEE2_UUID, description: "Pushes batch 1 cent over" }
      ]
    )

    assert_error_door(expected_code: "insufficient_funds")
    assert_empty fetch_all_payments
    assert_equal 2_000_000, firm_balance_cents(PAYER_UUID)
    assert_equal 100_000, firm_balance_cents(PAYEE1_UUID)
    assert_equal 0, firm_balance_cents(PAYEE2_UUID)
  end

  test "rejects amount 1 cent above PG INTEGER max (21474836.48)" do
    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "21474836.48", payee_firm_uuid: PAYEE1_UUID, description: "One cent over int4 max" } ]
    )

    body = assert_error_door(expected_code: "amount_exceeds_limit")
    assert_equal "payments[0].amount", body.dig("error", "field")
    assert_equal 0, body.dig("error", "payment_index")
    assert_empty fetch_all_payments
  end

  test "rejects empty batch (0 items) and oversized batch (1001 items)" do
    post_json(payer_firm_uuid: PAYER_UUID, payments: [])
    assert_error_door(expected_code: "invalid_batch_size")

    oversized = Array.new(1_001) do |idx|
      { amount: "0.01", payee_firm_uuid: PAYEE1_UUID, description: "Item #{idx}" }
    end
    post_json(payer_firm_uuid: PAYER_UUID, payments: oversized)
    assert_error_door(expected_code: "invalid_batch_size")

    assert_empty fetch_all_payments
  end

  test "rejects every prohibited amount format and non-string amount" do
    invalid_amounts = [
      [ "0", "non_positive_amount" ],
      [ "0.0", "non_positive_amount" ],
      [ "0.00", "non_positive_amount" ],
      [ "00", "invalid_amount_format" ],
      [ "01", "invalid_amount_format" ],
      [ "00.50", "invalid_amount_format" ],
      [ "01.23", "invalid_amount_format" ],
      [ ".50", "invalid_amount_format" ],
      [ "1.", "invalid_amount_format" ],
      [ "1.234", "invalid_amount_format" ],
      [ "1.000", "invalid_amount_format" ],
      [ "-10.00", "invalid_amount_format" ],
      [ "+10.00", "invalid_amount_format" ],
      [ "1e2", "invalid_amount_format" ],
      [ "1E2", "invalid_amount_format" ],
      [ "1.2e1", "invalid_amount_format" ],
      [ " 10.00", "invalid_amount_format" ],
      [ "10.00 ", "invalid_amount_format" ],
      [ "\t10.00", "invalid_amount_format" ],
      [ "10.00\n", "invalid_amount_format" ],
      [ "1,000.00", "invalid_amount_format" ],
      [ "$10.00", "invalid_amount_format" ],
      [ "NaN", "invalid_amount_format" ],
      [ "Infinity", "invalid_amount_format" ],
      [ "", "invalid_amount_format" ],
      [ "10..50", "invalid_amount_format" ],
      [ "１０.００", "invalid_amount_format" ], # Full-width Unicode digits
      [ 100, "invalid_amount_type" ],
      [ 100.5, "invalid_amount_type" ],
      [ nil, "invalid_amount_type" ],
      [ true, "invalid_amount_type" ],
      [ [ "10" ], "invalid_amount_type" ],
      [ { "usd" => "10" }, "invalid_amount_type" ]
    ]

    invalid_amounts.each do |bad_amount, expected_code|
      post_json(
        payer_firm_uuid: PAYER_UUID,
        payments: [ { amount: bad_amount, payee_firm_uuid: PAYEE1_UUID, description: "Amount test" } ]
      )
      body = assert_error_door(expected_code: expected_code, context: "amount=#{bad_amount.inspect}")
      assert_equal "payments[0].amount", body.dig("error", "field")
    end

    assert_empty fetch_all_payments
  end

  test "rejects self-payments (even when mixed with valid payments) and persists nothing" do
    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [
        { amount: "10.00", payee_firm_uuid: PAYEE1_UUID, description: "Valid leg" },
        { amount: "5.00", payee_firm_uuid: PAYER_UUID, description: "Self transfer leg" }
      ]
    )

    body = assert_error_door(expected_code: "self_payment")
    assert_equal 1, body.dig("error", "payment_index")
    assert_empty fetch_all_payments
    assert_equal 2_000_000, firm_balance_cents(PAYER_UUID)
  end

  test "rejects malformed JSON and invalid UTF-8 with 422 and detailed explanation" do
    malformed_bodies = [
      "",
      "   \n\t  ",
      "{",
      "{\"payer_firm_uuid\": \"#{PAYER_UUID}\",}",
      "{\"payer_firm_uuid\": \"#{PAYER_UUID}\", \"payments\": [}",
      "not json at all",
      "{\"payer_firm_uuid\": \"#{PAYER_UUID}\"} trailing",
      "{\"payer_firm_uuid\": \"\xFF\xFE\"}"
    ]

    malformed_bodies.each do |raw|
      post_raw(raw)
      assert_error_door(expected_code: "malformed_json", context: "raw=#{raw.inspect}")
    end
  end

  test "rejects invalid UUID syntax and non-existent payer or payee UUIDs with 422" do
    bad_uuids = [
      "",
      "not-a-uuid",
      "3f1c9a2e7b4d4c1e9a552d8e6f0b7c41", # missing hyphens
      "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c4", # 1 char short
      "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41aa", # too long
      "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c4g", # non-hex char
      " 3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
      12345,
      nil
    ]

    bad_uuids.each do |bad_uuid|
      post_json(
        payer_firm_uuid: bad_uuid,
        payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Bad payer UUID" } ]
      )
      assert_error_door(expected_code: "invalid_uuid", context: "payer=#{bad_uuid.inspect}")

      post_json(
        payer_firm_uuid: PAYER_UUID,
        payments: [ { amount: "1.00", payee_firm_uuid: bad_uuid, description: "Bad payee UUID" } ]
      )
      assert_error_door(expected_code: "invalid_uuid", context: "payee=#{bad_uuid.inspect}")
    end

    # Existing syntax, unknown payer firm
    post_json(
      payer_firm_uuid: MISSING_UUID,
      payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Unknown payer" } ]
    )
    assert_error_door(expected_code: "unknown_payer_firm")

    # Existing syntax, unknown payee firm on second item -> atomic rollback of whole batch
    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [
        { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Valid first payee" },
        { amount: "1.00", payee_firm_uuid: MISSING_UUID, description: "Unknown second payee" }
      ]
    )
    body = assert_error_door(expected_code: "unknown_payee_firm")
    assert_equal 1, body.dig("error", "payment_index")
    assert_empty fetch_all_payments
  end

  test "rejects missing, non-string, null-byte, or whitespace-only descriptions" do
    invalid_descriptions = [
      [ nil, "invalid_description_type" ],
      [ 123, "invalid_description_type" ],
      [ false, "invalid_description_type" ],
      [ [], "invalid_description_type" ],
      [ {}, "invalid_description_type" ],
      [ "", "blank_description" ],
      [ "   ", "blank_description" ],
      [ "\t\r\n\v\f", "blank_description" ],
      [ "\u00A0\u2003", "blank_description" ],
      [ "Invoice\u0000123", "invalid_description" ]
    ]

    invalid_descriptions.each do |bad_desc, expected_code|
      post_json(
        payer_firm_uuid: PAYER_UUID,
        payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: bad_desc } ]
      )
      assert_error_door(expected_code: expected_code, context: "desc=#{bad_desc.inspect}")
    end

    assert_empty fetch_all_payments
  end

  test "rejects invalid root shapes, missing keys, and extra unknown keys" do
    [ "[]", "123", "\"hello\"", "true", "null" ].each do |non_object_json|
      post_raw(non_object_json)
      assert_error_door(expected_code: "invalid_payload_shape")
    end

    post_json(payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "No payer" } ])
    assert_error_door(expected_code: "missing_required_field")

    post_json(payer_firm_uuid: PAYER_UUID)
    assert_error_door(expected_code: "missing_required_field")

    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Extra root" } ],
      extra: "nope"
    )
    assert_error_door(expected_code: "unexpected_fields")

    post_json(payer_firm_uuid: PAYER_UUID, payments: "not-an-array")
    assert_error_door(expected_code: "invalid_payments_type")

    post_json(payer_firm_uuid: PAYER_UUID, payments: [ "not-an-object" ])
    assert_error_door(expected_code: "invalid_payment_item")

    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID } ]
    )
    assert_error_door(expected_code: "missing_required_field")

    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Ok", currency: "USD" } ]
    )
    assert_error_door(expected_code: "unexpected_fields")
  end

  test "only POST /bulk_payments exists in the routing table" do
    routes = Rails.application.routes.routes.reject(&:internal).map do |route|
      "#{route.verb} #{route.path.spec}"
    end
    assert_equal [ "POST /bulk_payments(.:format)" ], routes
  end

  test "returns generic 500 JSON without leaking SQL or stack traces on unexpected internal failures" do
    # Temporarily stub BulkPayments::Poster.call to simulate an unexpected internal exception
    original_call = BulkPayments::Poster.method(:call)
    log_output = StringIO.new
    original_logger = Rails.logger

    BulkPayments::Poster.define_singleton_method(:call) do |_batch|
      raise RuntimeError, "Simulated secret SQL failure SELECT * FROM secret_internal_state"
    end
    Rails.logger = ActiveSupport::Logger.new(log_output)

    begin
      post_json(
        payer_firm_uuid: PAYER_UUID,
        payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Trigger internal failure" } ]
      )

      assert_response :internal_server_error
      body = JSON.parse(response.body)
      assert_equal "internal_error", body.dig("error", "code")
      assert body.dig("error", "what").present?
      assert body.dig("error", "why").present?
      assert body.dig("error", "how_to_fix").present?
      refute_includes response.body, "secret_internal_state"
      refute_includes response.body, "RuntimeError"
      assert_includes log_output.string, "Simulated secret SQL failure"
    ensure
      BulkPayments::Poster.define_singleton_method(:call, original_call)
      Rails.logger = original_logger
    end
  end

  private

    def post_json(payload)
      post_raw(JSON.generate(payload))
    end

    def post_raw(raw_body)
      post "/bulk_payments",
        params: raw_body,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
    end

    def assert_error_door(expected_code:, context: nil)
      assert_response :unprocessable_content, "Expected 422 (#{context}), got #{response.status}: #{response.body}"
      body = JSON.parse(response.body)
      err = body["error"]
      assert_kind_of Hash, err, "Missing error object (#{context})"
      assert_equal expected_code, err["code"], "Unexpected error code (#{context}): #{body.inspect}"
      assert err["what"].is_a?(String) && err["what"].present?, "Missing 'what' (#{context})"
      assert err["why"].is_a?(String) && err["why"].present?, "Missing 'why' (#{context})"
      assert err["how_to_fix"].is_a?(String) && err["how_to_fix"].present?, "Missing 'how_to_fix' (#{context})"
      body
    end
end

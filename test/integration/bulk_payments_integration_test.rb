# frozen_string_literal: true

require "test_helper"

class BulkPaymentsIntegrationTest < ActionDispatch::IntegrationTest
  PAYER_UUID   = "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41"
  PAYEE1_UUID  = "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25"
  PAYEE2_UUID  = "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10"
  MISSING_UUID = "11111111-2222-4333-8444-555555555555"

  PERMITTED_ERROR_KEYS = %w[code what why how_to_fix field payment_index].freeze

  setup do
    @payer  = create_firm!(name: "Payer CPA LLC", opening_balance_cents: 2_000_000, uuid: PAYER_UUID)
    @payee1 = create_firm!(name: "Payee One Advisors", opening_balance_cents: 100_000, uuid: PAYEE1_UUID)
    @payee2 = create_firm!(name: "Payee Two Bookkeeping", opening_balance_cents: 0, uuid: PAYEE2_UUID)
  end

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
    body = JSON.parse(response.body)
    by_id = fetch_all_payments.index_by { |r| r[:id] }
    ordered_rows = body.fetch("payment_ids").map do |id|
      row = by_id.fetch(id)
      [ row[:payer_firm_id], row[:payee_firm_id], row[:amount_cents], row[:description] ]
    end

    assert_equal(
      {
        status: 201,
        payer_firm_uuid: PAYER_UUID,
        payments_count: 3,
        unique_ids_count: 3,
        total_stored: 3,
        balances: { payer: 674_875, payee1: 1_305_050, payee2: 120_075 },
        ordered_rows: [
          [ @payer.id, @payee1.id, 625_000, "Overflow returns, August 2026" ],
          [ @payer.id, @payee1.id, 580_050, "Amended returns, August 2026" ],
          [ @payer.id, @payee2.id, 120_075, "Bookkeeping cleanup, 3 clients" ]
        ]
      },
      {
        status: response.status,
        payer_firm_uuid: body["payer_firm_uuid"],
        payments_count: body["payments_count"],
        unique_ids_count: body.fetch("payment_ids").uniq.size,
        total_stored: by_id.size,
        balances: current_balances,
        ordered_rows: ordered_rows
      }
    )
  end

  test "returns payment_ids strictly ordered by source payment index regardless of payee join order" do
    firm_early = create_firm!(name: "Early ID Payee", opening_balance_cents: 0)
    firm_late  = create_firm!(name: "Late ID Payee", opening_balance_cents: 0)

    # Interleave payee IDs (`firm_late` -> `@payee2` -> `firm_early` -> `firm_late` -> `@payee1`)
    # so any hash/index join reordering without `ORDER BY inserted.ord` scrambles `payment_ids`.
    legs = [
      { amount: "1.01", payee_firm_uuid: firm_late.uuid, description: "Ord 0" },
      { amount: "2.02", payee_firm_uuid: PAYEE2_UUID, description: "Ord 1" },
      { amount: "3.03", payee_firm_uuid: firm_early.uuid, description: "Ord 2" },
      { amount: "4.04", payee_firm_uuid: firm_late.uuid, description: "Ord 3" },
      { amount: "5.05", payee_firm_uuid: PAYEE1_UUID, description: "Ord 4" }
    ]

    post_json(payer_firm_uuid: PAYER_UUID, payments: legs)
    returned_ids = JSON.parse(response.body).fetch("payment_ids")
    by_id = fetch_all_payments.index_by { |r| r[:id] }

    assert_equal(
      {
        status: 201,
        ordered_legs: [
          [ firm_late.id, 101, "Ord 0" ],
          [ @payee2.id, 202, "Ord 1" ],
          [ firm_early.id, 303, "Ord 2" ],
          [ firm_late.id, 404, "Ord 3" ],
          [ @payee1.id, 505, "Ord 4" ]
        ]
      },
      {
        status: response.status,
        ordered_legs: returned_ids.map { |id| by_id.fetch(id).values_at(:payee_firm_id, :amount_cents, :description) }
      }
    )
  end

  test "appends repeated items within a batch and across repeated Idempotency-Key requests without deduplication" do
    identical_item = {
      amount: "100.25",
      payee_firm_uuid: PAYEE1_UUID,
      description: "Duplicate retainer installment"
    }

    post_json(payer_firm_uuid: PAYER_UUID, payments: [ identical_item, identical_item.dup, identical_item.dup ])
    batch_body = JSON.parse(response.body)

    assert_equal(
      {
        status: 201,
        payments_count: 3,
        unique_ids: 3,
        stored_amounts: [ 10_025, 10_025, 10_025 ],
        balances: { payer: 1_969_925, payee1: 130_075, payee2: 0 }
      },
      {
        status: response.status,
        payments_count: batch_body["payments_count"],
        unique_ids: batch_body.fetch("payment_ids").uniq.size,
        stored_amounts: fetch_all_payments.map { |r| r[:amount_cents] },
        balances: current_balances
      }
    )

    # HTTP `Idempotency-Key` is intentionally out of scope; repeating the header appends distinct transfers.
    idem_headers = { "CONTENT_TYPE" => "application/json", "Idempotency-Key" => "same-key-123" }
    idem_body = JSON.generate(
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "10.00", payee_firm_uuid: PAYEE2_UUID, description: "Non-idempotent transfer" } ]
    )

    statuses = 2.times.map do
      post "/bulk_payments", params: idem_body, headers: idem_headers
      response.status
    end

    assert_equal(
      { statuses: [ 201, 201 ], total_rows: 5, payer_balance: 1_967_925, payee2_balance: 2_000 },
      {
        statuses: statuses,
        total_rows: fetch_all_payments.size,
        payer_balance: firm_balance_cents(PAYER_UUID),
        payee2_balance: firm_balance_cents(PAYEE2_UUID)
      }
    )
  end

  test "enforces batch cardinality thresholds across 0, 1, 1000, and 1001 items" do
    oversized = Array.new(1_001) { |idx| { amount: "0.01", payee_firm_uuid: PAYEE1_UUID, description: "Item #{idx}" } }

    assert_table([ [ "empty_batch_0", [] ], [ "oversized_batch_1001", oversized ] ]) do |label, items|
      [
        label,
        { status: 422, door_valid: true, code: "invalid_batch_size", field: "payments", sql_queries: 0 },
        post_door({ payer_firm_uuid: PAYER_UUID, payments: items })
      ]
    end

    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [ { amount: "0.01", payee_firm_uuid: PAYEE1_UUID, description: "Single item batch" } ]
    )
    single_status = [ response.status, JSON.parse(response.body)["payments_count"] ]

    thousand_items = Array.new(1_000) do |idx|
      {
        amount: "0.01",
        payee_firm_uuid: idx.even? ? PAYEE1_UUID : PAYEE2_UUID,
        description: "Batch item ##{idx} with 'quotes' and \\backslashes\\"
      }
    end
    post_json(payer_firm_uuid: PAYER_UUID, payments: thousand_items)

    assert_equal(
      {
        single: [ 201, 1 ],
        thousand: [ 201, 1_000 ],
        stored_count: 1_001,
        balances: { payer: 2_000_000 - 1_001, payee1: 100_000 + 501, payee2: 500 }
      },
      {
        single: single_status,
        thousand: [ response.status, JSON.parse(response.body)["payments_count"] ],
        stored_count: fetch_all_payments.size,
        balances: current_balances
      }
    )
  end

  test "enforces balance sufficiency at zero empty-history funds, 1 cent short rollback, and exact drain to zero" do
    # `@payee2` starts at `opening_balance_cents = 0` with zero incoming/outgoing rows (`COALESCE(NULL, 0)` on both sums).
    zero_history_attempt = post_door(
      { payer_firm_uuid: PAYEE2_UUID, payments: [ { amount: "0.01", payee_firm_uuid: PAYEE1_UUID, description: "Empty history spend" } ] },
      track_sql: false
    )
    assert_equal(
      { door: { status: 422, door_valid: true, code: "insufficient_funds", field: "payments" }, stored: 0 },
      { door: zero_history_attempt, stored: fetch_all_payments.size }
    )

    # First leg fits alone, second pushes gross total 1 cent over 2,000,000 -> entire batch rolls back.
    one_cent_over = post_door(
      {
        payer_firm_uuid: PAYER_UUID,
        payments: [
          { amount: "10000.00", payee_firm_uuid: PAYEE1_UUID, description: "Fits alone" },
          { amount: "10000.01", payee_firm_uuid: PAYEE2_UUID, description: "1 cent over gross" }
        ]
      },
      track_sql: false
    )
    assert_equal(
      {
        door: { status: 422, door_valid: true, code: "insufficient_funds", field: "payments" },
        stored: 0,
        balances: { payer: 2_000_000, payee1: 100_000, payee2: 0 }
      },
      { door: one_cent_over, stored: fetch_all_payments.size, balances: current_balances }
    )

    # Exact gross match drains sender to 0; subsequent 1-cent spend fails.
    post_json(
      payer_firm_uuid: PAYER_UUID,
      payments: [
        { amount: "10000.00", payee_firm_uuid: PAYEE1_UUID, description: "Half 1" },
        { amount: "10000", payee_firm_uuid: PAYEE2_UUID, description: "Half 2" }
      ]
    )
    drain_status = response.status
    exhausted_attempt = post_door(
      { payer_firm_uuid: PAYER_UUID, payments: [ { amount: "0.01", payee_firm_uuid: PAYEE1_UUID, description: "Post-drain cent" } ] },
      track_sql: false
    )

    assert_equal(
      {
        drain_status: 201,
        exhausted_code: "insufficient_funds",
        stored: 2,
        balances: { payer: 0, payee1: 1_100_000, payee2: 1_000_000 }
      },
      {
        drain_status: drain_status,
        exhausted_code: exhausted_attempt[:code],
        stored: fetch_all_payments.size,
        balances: current_balances
      }
    )
  end

  test "enforces per-payment int4 ceiling (21474836.47 vs 21474836.48) while allowing uncapped NUMERIC balances and batch totals" do
    over_int4 = post_door(
      {
        payer_firm_uuid: PAYER_UUID,
        payments: [ { amount: "21474836.48", payee_firm_uuid: PAYEE1_UUID, description: "One cent over int4 max" } ]
      }
    )
    assert_equal(
      { status: 422, door_valid: true, code: "amount_exceeds_limit", field: "payments[0].amount", payment_index: 0, sql_queries: 0 },
      over_int4
    )

    max_int4 = 2_147_483_647
    whale_payer = create_firm!(name: "Whale Sender", opening_balance_cents: max_int4)
    feeder1 = create_firm!(name: "Feeder 1", opening_balance_cents: max_int4)
    feeder2 = create_firm!(name: "Feeder 2", opening_balance_cents: max_int4)

    # 3 * 2,147,483,647 = 6,442,450,941 cents (> PostgreSQL `int4` max, proving `NUMERIC` derived balances and batch sums).
    [ feeder1, feeder2 ].each_with_index do |feeder, idx|
      post_json(
        payer_firm_uuid: feeder.uuid,
        payments: [ { amount: "21474836.47", payee_firm_uuid: whale_payer.uuid, description: "Top up #{idx}" } ]
      )
    end
    accumulated_whale_balance = firm_balance_cents(whale_payer.uuid)

    post_json(
      payer_firm_uuid: whale_payer.uuid,
      payments: Array.new(3) { |i| { amount: "21474836.47", payee_firm_uuid: PAYEE2_UUID, description: "Max int4 leg #{i}" } }
    )

    assert_equal(
      {
        accumulated_before_spend: 6_442_450_941,
        spend_status: 201,
        whale_after_spend: 0,
        recipient_balance: 6_442_450_941
      },
      {
        accumulated_before_spend: accumulated_whale_balance,
        spend_status: response.status,
        whale_after_spend: firm_balance_cents(whale_payer.uuid),
        recipient_balance: firm_balance_cents(PAYEE2_UUID)
      }
    )
  end

  test "converts valid USD decimal strings to exact cents without float drift and rejects prohibited amount formats at Layer 1" do
    # Includes IEEE-754 binary float traps (`0.29 * 100 == 28.999999999999996`, `19.99 * 100 == 1998.9999999999998`).
    valid_pairs = [
      [ "1", 100 ],
      [ "1.2", 120 ],
      [ "1.23", 123 ],
      [ "0.01", 1 ],
      [ "0.50", 50 ],
      [ "0.29", 29 ],
      [ "19.99", 1999 ],
      [ "9999.90", 999_990 ]
    ]

    post_json(
      payer_firm_uuid: PAYER_UUID.upcase,
      payments: valid_pairs.map.with_index do |(amt, _), idx|
        { amount: amt, payee_firm_uuid: PAYEE1_UUID.upcase, description: "Valid format #{idx} " }
      end
    )
    returned_ids = JSON.parse(response.body).fetch("payment_ids")
    by_id = fetch_all_payments.index_by { |r| r[:id] }
    ordered_rows = returned_ids.map { |id| by_id.fetch(id) }

    assert_equal(
      { status: 201, cents: valid_pairs.map(&:last), first_description: "Valid format 0 " },
      {
        status: response.status,
        cents: ordered_rows.map { |r| r[:amount_cents] },
        first_description: ordered_rows.first[:description]
      }
    )

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
      [ "１０.００", "invalid_amount_format" ], # U+FF11/U+FF10 full-width Unicode digits (visually resemble ASCII)
      [ 100, "invalid_amount_type" ],
      [ 100.5, "invalid_amount_type" ],
      [ nil, "invalid_amount_type" ],
      [ true, "invalid_amount_type" ],
      [ [ "10" ], "invalid_amount_type" ],
      [ { "usd" => "10" }, "invalid_amount_type" ]
    ]

    assert_table(invalid_amounts) do |bad_amount, expected_code|
      [
        "amount=#{bad_amount.inspect}",
        {
          status: 422,
          door_valid: true,
          code: expected_code,
          field: "payments[0].amount",
          payment_index: 0,
          sql_queries: 0
        },
        post_door(
          {
            payer_firm_uuid: PAYER_UUID,
            payments: [ { amount: bad_amount, payee_firm_uuid: PAYEE1_UUID, description: "Amount check" } ]
          }
        )
      ]
    end
  end

  test "rejects malformed JSON, invalid UTF-8, and invalid envelope shapes at Layer 1 without touching PostgreSQL" do
    wire_and_envelope_cases = [
      [ "empty_body", "", true, { code: "malformed_json" } ],
      [ "whitespace_body", "   \n\t  ", true, { code: "malformed_json" } ],
      [ "unclosed_brace", "{", true, { code: "malformed_json" } ],
      [ "trailing_comma", "{\"payer_firm_uuid\": \"#{PAYER_UUID}\",}", true, { code: "malformed_json" } ],
      [ "broken_array", "{\"payer_firm_uuid\": \"#{PAYER_UUID}\", \"payments\": [}", true, { code: "malformed_json" } ],
      [ "bare_words", "not json at all", true, { code: "malformed_json" } ],
      [ "trailing_tokens", "{\"payer_firm_uuid\": \"#{PAYER_UUID}\"} trailing", true, { code: "malformed_json" } ],
      [ "invalid_utf8", "{\"payer_firm_uuid\": \"\xFF\xFE\"}", true, { code: "malformed_json" } ],
      [ "root_array", "[]", true, { code: "invalid_payload_shape" } ],
      [ "root_number", "123", true, { code: "invalid_payload_shape" } ],
      [ "root_string", "\"hello\"", true, { code: "invalid_payload_shape" } ],
      [ "root_boolean", "true", true, { code: "invalid_payload_shape" } ],
      [ "root_null", "null", true, { code: "invalid_payload_shape" } ],
      [
        "missing_payer_firm_uuid",
        { payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "No payer" } ] },
        false,
        { code: "missing_required_field", field: "payer_firm_uuid" }
      ],
      [
        "missing_payments",
        { payer_firm_uuid: PAYER_UUID },
        false,
        { code: "missing_required_field", field: "payments" }
      ],
      [
        "extra_root_key",
        {
          payer_firm_uuid: PAYER_UUID,
          payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Extra root" } ],
          extra: "nope"
        },
        false,
        { code: "unexpected_fields", field: "extra" }
      ],
      [
        "non_array_payments",
        { payer_firm_uuid: PAYER_UUID, payments: "not-an-array" },
        false,
        { code: "invalid_payments_type", field: "payments" }
      ],
      [
        "non_object_payment_item",
        { payer_firm_uuid: PAYER_UUID, payments: [ "not-an-object" ] },
        false,
        { code: "invalid_payment_item", field: "payments[0]", payment_index: 0 }
      ],
      [
        "missing_item_description",
        { payer_firm_uuid: PAYER_UUID, payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID } ] },
        false,
        { code: "missing_required_field", field: "payments[0].description", payment_index: 0 }
      ],
      [
        "extra_item_key",
        {
          payer_firm_uuid: PAYER_UUID,
          payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Ok", currency: "USD" } ]
        },
        false,
        { code: "unexpected_fields", field: "payments[0].currency", payment_index: 0 }
      ]
    ]

    assert_table(wire_and_envelope_cases) do |label, payload, is_raw, expected_fields|
      [
        label,
        { status: 422, door_valid: true, sql_queries: 0 }.merge(expected_fields),
        post_door(payload, raw: is_raw)
      ]
    end
  end

  test "enforces party UUID syntax and self-payment shortcuts at Layer 1 (0 SQL) and firm existence rollback at Layer 2" do
    bad_uuids = [
      "",
      "not-a-uuid",
      "3f1c9a2e7b4d4c1e9a552d8e6f0b7c41",
      "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c4",
      "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41aa",
      "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c4g",
      " 3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
      12_345,
      nil
    ]

    layer1_cases = bad_uuids.flat_map do |bad_uuid|
      [
        [
          "payer_uuid=#{bad_uuid.inspect}",
          { payer_firm_uuid: bad_uuid, payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Bad payer" } ] },
          { code: "invalid_uuid", field: "payer_firm_uuid" }
        ],
        [
          "payee_uuid=#{bad_uuid.inspect}",
          { payer_firm_uuid: PAYER_UUID, payments: [ { amount: "1.00", payee_firm_uuid: bad_uuid, description: "Bad payee" } ] },
          { code: "invalid_uuid", field: "payments[0].payee_firm_uuid", payment_index: 0 }
        ]
      ]
    end

    layer1_cases << [
      "self_payment_exact_case",
      {
        payer_firm_uuid: PAYER_UUID,
        payments: [
          { amount: "10.00", payee_firm_uuid: PAYEE1_UUID, description: "Valid leg" },
          { amount: "5.00", payee_firm_uuid: PAYER_UUID, description: "Self leg" }
        ]
      },
      { code: "self_payment", field: "payments[1].payee_firm_uuid", payment_index: 1 }
    ]

    layer1_cases << [
      "self_payment_mixed_case",
      {
        payer_firm_uuid: PAYER_UUID.upcase,
        payments: [ { amount: "5.00", payee_firm_uuid: PAYER_UUID.downcase, description: "Case-folded self leg" } ]
      },
      { code: "self_payment", field: "payments[0].payee_firm_uuid", payment_index: 0 }
    ]

    assert_table(layer1_cases) do |label, payload, expected_fields|
      [
        label,
        { status: 422, door_valid: true, sql_queries: 0 }.merge(expected_fields),
        post_door(payload)
      ]
    end

    unknown_payer_door = post_door(
      { payer_firm_uuid: MISSING_UUID, payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Unknown payer" } ] },
      track_sql: false
    )
    unknown_payee_door = post_door(
      {
        payer_firm_uuid: PAYER_UUID,
        payments: [
          { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Valid first payee" },
          { amount: "1.00", payee_firm_uuid: MISSING_UUID, description: "Unknown second payee" }
        ]
      },
      track_sql: false
    )

    assert_equal(
      {
        unknown_payer: { status: 422, door_valid: true, code: "unknown_payer_firm", field: "payer_firm_uuid" },
        unknown_payee: {
          status: 422,
          door_valid: true,
          code: "unknown_payee_firm",
          field: "payments[1].payee_firm_uuid",
          payment_index: 1
        },
        stored: 0,
        balances: { payer: 2_000_000, payee1: 100_000, payee2: 0 }
      },
      {
        unknown_payer: unknown_payer_door,
        unknown_payee: unknown_payee_door,
        stored: fetch_all_payments.size,
        balances: current_balances
      }
    )
  end

  test "rejects non-string, whitespace-only, and null-byte descriptions at Layer 1 without touching PostgreSQL" do
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

    assert_table(invalid_descriptions) do |bad_desc, expected_code|
      [
        "desc=#{bad_desc.inspect}",
        {
          status: 422,
          door_valid: true,
          code: expected_code,
          field: "payments[0].description",
          payment_index: 0,
          sql_queries: 0
        },
        post_door(
          {
            payer_firm_uuid: PAYER_UUID,
            payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: bad_desc } ]
          }
        )
      ]
    end
  end

  test "only POST /bulk_payments exists in the routing table" do
    routes = Rails.application.routes.routes.reject(&:internal).map do |route|
      "#{route.verb} #{route.path.spec}"
    end
    assert_equal [ "POST /bulk_payments(.:format)" ], routes
  end

  test "returns generic 500 JSON without leaking SQL or stack traces when an unexpected database failure occurs" do
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_output)

    admin_connection.exec(
      "REVOKE EXECUTE ON FUNCTION public.post_bulk_payments(UUID, UUID[], INTEGER[], TEXT[]) FROM ledger_runtime"
    )

    begin
      post_json(
        payer_firm_uuid: PAYER_UUID,
        payments: [ { amount: "1.00", payee_firm_uuid: PAYEE1_UUID, description: "Triggers unmapped PG privilege fault" } ]
      )

      door = post_door_from_last_response
      leaked_tokens = %w[post_bulk_payments InsufficientPrivilege StatementInvalid SELECT app/].select do |secret|
        response.body.include?(secret)
      end

      assert_equal(
        {
          door: { status: 500, door_valid: true, code: "internal_error" },
          leaked_in_response: [],
          logged_real_fault: true,
          stored: 0
        },
        {
          door: door,
          leaked_in_response: leaked_tokens,
          logged_real_fault: log_output.string.include?("PG::InsufficientPrivilege") &&
                             log_output.string.include?("post_bulk_payments"),
          stored: fetch_all_payments.size
        }
      )
    ensure
      admin_connection.exec(
        "GRANT EXECUTE ON FUNCTION public.post_bulk_payments(UUID, UUID[], INTEGER[], TEXT[]) TO ledger_runtime"
      )
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

    def post_door(raw_or_hash, raw: false, track_sql: true)
      _, sql_queries = count_sql_queries do
        raw ? post_raw(raw_or_hash) : post_json(raw_or_hash)
      end

      snapshot = post_door_from_last_response
      snapshot[:sql_queries] = sql_queries if track_sql
      snapshot
    end

    def post_door_from_last_response
      parsed = JSON.parse(response.body) rescue nil
      err = parsed.is_a?(Hash) ? parsed["error"] : nil
      prose_valid = err.is_a?(Hash) &&
        (err.keys - PERMITTED_ERROR_KEYS).empty? &&
        %w[what why how_to_fix].all? { |k| err[k].is_a?(String) && err[k].present? }

      {
        status: response.status,
        door_valid: prose_valid,
        code: err&.dig("code"),
        field: err&.dig("field"),
        payment_index: err&.dig("payment_index")
      }.compact
    end

    def current_balances
      {
        payer: firm_balance_cents(PAYER_UUID),
        payee1: firm_balance_cents(PAYEE1_UUID),
        payee2: firm_balance_cents(PAYEE2_UUID)
      }
    end
end

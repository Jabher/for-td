# frozen_string_literal: true

require "test_helper"

class LedgerInvariantsAndSecurityTest < ActiveSupport::TestCase
  test "ledger_runtime role permits firm creation and name updates while rejecting ungranted column, table, view, and DDL operations" do
    firm = create_firm!(name: "Original Name", opening_balance_cents: 25_000)
    other = create_firm!(name: "Counterparty", opening_balance_cents: 10_000)
    firm.update!(name: "Updated Firm Name")

    reloaded = FirmDescription.find(firm.id)
    view_row = Firm.find(firm.id)
    assert_equal(
      {
        table_row: [ "Updated Firm Name", 25_000 ],
        view_row: [ "Updated Firm Name", 25_000 ]
      },
      {
        table_row: [ reloaded.name, reloaded.opening_balance_cents ],
        view_row: [ view_row.name, BigDecimal(view_row.balance_cents.to_s).to_i ]
      }
    )

    conn = ApplicationRecord.lease_connection
    forbidden_operations = [
      [ "update_opening_balance", "42501", -> { conn.exec_query("UPDATE public.firm_descriptions SET opening_balance_cents = 999999 WHERE id = $1", "ACL", [ firm.id ]) } ],
      [ "update_uuid", "42501", -> { conn.exec_query("UPDATE public.firm_descriptions SET uuid = $1::uuid WHERE id = $2", "ACL", [ "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", firm.id ]) } ],
      [ "update_id", "428C9", -> { conn.exec_query("UPDATE public.firm_descriptions SET id = 999 WHERE id = $1", "ACL", [ firm.id ]) } ],
      [ "update_created_at", "42501", -> { conn.exec_query("UPDATE public.firm_descriptions SET created_at = NOW() WHERE id = $1", "ACL", [ firm.id ]) } ],
      [ "delete_firm_descriptions", "42501", -> { conn.exec_query("DELETE FROM public.firm_descriptions WHERE id = $1", "ACL", [ firm.id ]) } ],
      [ "select_payments", "42501", -> { conn.execute("SELECT * FROM public.payments") } ],
      [ "insert_payments", "42501", -> { conn.execute("INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES (#{firm.id}, #{other.id}, 100, 'Bypass')") } ],
      [ "update_payments", "42501", -> { conn.execute("UPDATE public.payments SET amount_cents = 1") } ],
      [ "delete_payments", "42501", -> { conn.execute("DELETE FROM public.payments") } ],
      [ "truncate_payments", "42501", -> { conn.execute("TRUNCATE public.payments") } ],
      [ "delete_firms_view", "42501", -> { conn.execute("DELETE FROM public.firms") } ],
      [ "ddl_create_table", "42501", -> { conn.execute("CREATE TABLE public.rogue_table (id int)") } ],
      [ "ddl_drop_view", "42501", -> { conn.execute("DROP VIEW public.firms") } ],
      [ "ddl_alter_table", "42501", -> { conn.execute("ALTER TABLE public.firm_descriptions ADD COLUMN hacked boolean") } ]
    ]

    assert_table(forbidden_operations) do |label, expected_sqlstate, action|
      [ label, expected_sqlstate, capture_pg_error(include_target: false, &action) ]
    end
  end

  test "table CHECK, UNIQUE, and RESTRICT FOREIGN KEY constraints guard firm_descriptions and payments directly" do
    firm1 = create_firm!(name: "Firm One", opening_balance_cents: 50_000)
    firm2 = create_firm!(name: "Firm Two", opening_balance_cents: 10_000)
    conn = ApplicationRecord.lease_connection

    constraint_cases = [
      [
        "negative_opening_balance",
        [ "23514", "chk_firm_descriptions_opening_balance_non_negative" ],
        -> { conn.exec_query("INSERT INTO public.firm_descriptions (name, opening_balance_cents) VALUES ($1, $2)", "Chk", [ "Bad Firm", -1 ]) }
      ],
      [
        "blank_firm_name",
        [ "23514", "chk_firm_descriptions_name_not_blank" ],
        -> { conn.exec_query("INSERT INTO public.firm_descriptions (name, opening_balance_cents) VALUES ($1, $2)", "Chk", [ "   \t\r\n  ", 0 ]) }
      ],
      [
        "duplicate_firm_uuid",
        [ "23505", "idx_firm_descriptions_uuid_covering" ],
        -> { conn.exec_query("INSERT INTO public.firm_descriptions (uuid, name, opening_balance_cents) VALUES ($1::uuid, $2, $3)", "Uniq", [ firm1.uuid, "Dup UUID", 0 ]) }
      ],
      [
        "zero_payment_amount",
        [ "23514", "chk_payments_positive_amount" ],
        -> { admin_connection.exec_params("INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES ($1, $2, 0, 'Zero')", [ firm1.id, firm2.id ]) }
      ],
      [
        "negative_payment_amount",
        [ "23514", "chk_payments_positive_amount" ],
        -> { admin_connection.exec_params("INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES ($1, $2, -10, 'Neg')", [ firm1.id, firm2.id ]) }
      ],
      [
        "self_transfer_row",
        [ "23514", "chk_payments_no_self_transfer" ],
        -> { admin_connection.exec_params("INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES ($1, $1, 100, 'Self')", [ firm1.id ]) }
      ],
      [
        "blank_payment_description",
        [ "23514", "chk_payments_description_not_blank" ],
        -> { admin_connection.exec_params("INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES ($1, $2, 100, E' \\t\\r\\n')", [ firm1.id, firm2.id ]) }
      ],
      [
        "missing_payer_fk",
        [ "23503", "fk_payments_payer_firm" ],
        -> { admin_connection.exec_params("INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES ($1, $2, 100, 'Missing payer')", [ 999_999, firm2.id ]) }
      ],
      [
        "missing_payee_fk",
        [ "23503", "fk_payments_payee_firm" ],
        -> { admin_connection.exec_params("INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES ($1, $2, 100, 'Missing payee')", [ firm1.id, 999_999 ]) }
      ]
    ]

    assert_table(constraint_cases) do |label, expected, action|
      [ label, expected, capture_pg_error(&action) ]
    end
  end

  test "immutability triggers block updates, deletes, and truncates on payments and immutable firm columns even for superuser/admin roles" do
    payer = create_firm!(name: "Payer", opening_balance_cents: 5_000)
    payee = create_firm!(name: "Payee", opening_balance_cents: 0)

    BulkPayments::Poster.call(
      BulkPayments::PayloadParser::ParsedBatch.new(
        payer_firm_uuid: payer.uuid,
        payee_firm_uuids: [ payee.uuid ],
        amounts_cents: [ 1_500 ],
        descriptions: [ "Immutable payment" ]
      )
    )
    payment_id = fetch_all_payments.first.fetch(:id)

    privileged_mutations = [
      [ "update_payment_amount", [ "55000", "payment_immutable" ], -> { admin_connection.exec_params("UPDATE public.payments SET amount_cents = 1 WHERE id = $1", [ payment_id ]) } ],
      [ "update_payment_description", [ "55000", "payment_immutable" ], -> { admin_connection.exec_params("UPDATE public.payments SET description = 'Tampered' WHERE id = $1", [ payment_id ]) } ],
      [ "delete_payment", [ "55000", "payment_immutable" ], -> { admin_connection.exec_params("DELETE FROM public.payments WHERE id = $1", [ payment_id ]) } ],
      [ "truncate_payments", [ "55000", "payment_immutable" ], -> { admin_connection.exec("TRUNCATE public.payments") } ],
      [ "update_firm_opening_balance", [ "55000", "firm_immutable_columns" ], -> { admin_connection.exec_params("UPDATE public.firm_descriptions SET opening_balance_cents = 999999 WHERE id = $1", [ payer.id ]) } ],
      [ "update_firm_uuid", [ "55000", "firm_immutable_columns" ], -> { admin_connection.exec_params("UPDATE public.firm_descriptions SET uuid = pg_catalog.uuidv7() WHERE id = $1", [ payer.id ]) } ],
      [ "update_firm_created_at", [ "55000", "firm_immutable_columns" ], -> { admin_connection.exec_params("UPDATE public.firm_descriptions SET created_at = NOW() - INTERVAL '1 day' WHERE id = $1", [ payer.id ]) } ],
      [ "delete_firm", [ "55000", "firm_immutable" ], -> { admin_connection.exec_params("DELETE FROM public.firm_descriptions WHERE id = $1", [ payee.id ]) } ],
      [ "truncate_firms", [ "55000", "firm_immutable" ], -> { admin_connection.exec("TRUNCATE public.firm_descriptions CASCADE") } ]
    ]

    assert_table(privileged_mutations) do |label, expected, action|
      [ label, expected, capture_pg_error(&action) ]
    end
  end

  test "post_bulk_payments enforces VOLATILE SECURITY DEFINER metadata and rejects non-READ COMMITTED or READ ONLY transactions" do
    fn_meta = admin_connection.exec(<<~SQL).first
      SELECT p.provolatile, p.prosecdef, pg_catalog.pg_get_userbyid(p.proowner) AS owner_name, p.proconfig
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'post_bulk_payments'
    SQL

    assert_equal(
      {
        provolatile: "v",
        prosecdef: "t",
        owner_name: "ledger_definer",
        proconfig: "{\"search_path=pg_catalog, pg_temp\"}"
      },
      {
        provolatile: fn_meta["provolatile"],
        prosecdef: fn_meta["prosecdef"],
        owner_name: fn_meta["owner_name"],
        proconfig: fn_meta["proconfig"]
      }
    )

    payer = create_firm!(name: "Iso Payer", opening_balance_cents: 10_000)
    payee = create_firm!(name: "Iso Payee", opening_balance_cents: 0)
    conn = ApplicationRecord.lease_connection
    post_sql = "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100]::int4[], ARRAY['Test']::text[])"

    tx_modes = [
      [
        "repeatable_read",
        [ "25001", "invalid_transaction_isolation" ],
        -> { conn.transaction(isolation: :repeatable_read, joinable: false) { conn.exec_query(post_sql, "IsoTest", [ payer.uuid, payee.uuid ]) } }
      ],
      [
        "serializable",
        [ "25001", "invalid_transaction_isolation" ],
        -> { conn.transaction(isolation: :serializable, joinable: false) { conn.exec_query(post_sql, "IsoTest", [ payer.uuid, payee.uuid ]) } }
      ],
      [
        "read_only",
        [ "25006", "read_only_transaction" ],
        lambda do
          conn.transaction(isolation: :read_committed, joinable: false) do
            conn.execute("SET LOCAL transaction_read_only = on")
            conn.exec_query(post_sql, "ReadOnlyTest", [ payer.uuid, payee.uuid ])
          end
        end
      ]
    ]

    assert_table(tx_modes) do |label, expected, action|
      [ label, expected, capture_pg_error(&action) ]
    end
  end

  test "Layer 2 SQL safeguards reject invalid direct arguments and translate into BulkPayments::Error doors when Layer 1 is bypassed" do
    payer = create_firm!(name: "Arg Payer", opening_balance_cents: 50_000)
    payee = create_firm!(name: "Arg Payee", opening_balance_cents: 0)
    conn = ApplicationRecord.lease_connection

    invalid_sql_calls = [
      [ "null_payer", [ "22004", "null_payer_firm_uuid" ], "SELECT public.post_bulk_payments(NULL::uuid, ARRAY[$1::uuid], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payee.uuid ] ],
      [ "null_arrays", [ "22004", "null_payment_arrays" ], "SELECT public.post_bulk_payments($1::uuid, NULL::uuid[], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payer.uuid ] ],
      [ "empty_arrays", [ "22023", "invalid_batch_size" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[]::uuid[], ARRAY[]::int4[], ARRAY[]::text[])", [ payer.uuid ] ],
      [ "oversized_1001", [ "22023", "invalid_batch_size" ], "SELECT public.post_bulk_payments($1::uuid, array_fill($2::uuid, ARRAY[1001]), array_fill(1::int4, ARRAY[1001]), array_fill('ok'::text, ARRAY[1001]))", [ payer.uuid, payee.uuid ] ],
      [ "mismatched_lengths", [ "2202E", "mismatched_array_lengths" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100, 200]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ] ],
      [ "two_dimensional", [ "2202E", "invalid_array_dimensions" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[[$2::uuid]], ARRAY[[100]]::int4[], ARRAY[['ok']]::text[])", [ payer.uuid, payee.uuid ] ],
      [ "non_1_lower_bound", [ "2202E", "invalid_array_dimensions" ], "SELECT public.post_bulk_payments($1::uuid, ('[2:2]={' || $2::text || '}')::uuid[], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ] ],
      [ "null_payee_element", [ "22004", "null_payee_firm_uuid" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[NULL::uuid], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payer.uuid ] ],
      [ "zero_amount", [ "22023", "invalid_amount_cents" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[0]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ] ],
      [ "negative_amount", [ "22023", "invalid_amount_cents" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[-50]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ] ],
      [ "null_amount_element", [ "22023", "invalid_amount_cents" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[NULL::int4], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ] ],
      [ "blank_description", [ "22023", "blank_description" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100]::int4[], ARRAY['   ']::text[])", [ payer.uuid, payee.uuid ] ],
      [ "null_description_element", [ "22023", "blank_description" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100]::int4[], ARRAY[NULL::text])", [ payer.uuid, payee.uuid ] ],
      [ "self_payment", [ "P0001", "self_payment" ], "SELECT public.post_bulk_payments($1::uuid, ARRAY[$1::uuid], ARRAY[100]::int4[], ARRAY['Self']::text[])", [ payer.uuid ] ]
    ]

    assert_table(invalid_sql_calls) do |label, expected, sql, binds|
      actual = capture_pg_error do
        conn.transaction(isolation: :read_committed, joinable: false) do
          conn.exec_query(sql, "DirectSqlSafeguard", binds)
        end
      end
      [ label, expected, actual ]
    end

    bypassed_batches = [
      [
        "poster_self_payment",
        BulkPayments::PayloadParser::ParsedBatch.new(payer_firm_uuid: payer.uuid, payee_firm_uuids: [ payer.uuid ], amounts_cents: [ 500 ], descriptions: [ "Self" ]),
        { code: "self_payment", field: "payments[0].payee_firm_uuid", payment_index: 0 }
      ],
      [
        "poster_empty_batch",
        BulkPayments::PayloadParser::ParsedBatch.new(payer_firm_uuid: payer.uuid, payee_firm_uuids: [], amounts_cents: [], descriptions: []),
        { code: "invalid_batch_size", field: "payments" }
      ],
      [
        "poster_non_positive_amount",
        BulkPayments::PayloadParser::ParsedBatch.new(payer_firm_uuid: payer.uuid, payee_firm_uuids: [ payee.uuid ], amounts_cents: [ 0 ], descriptions: [ "Zero" ]),
        { code: "invalid_amount", field: "payments", payment_index: 0 }
      ],
      [
        "poster_blank_description",
        BulkPayments::PayloadParser::ParsedBatch.new(payer_firm_uuid: payer.uuid, payee_firm_uuids: [ payee.uuid ], amounts_cents: [ 100 ], descriptions: [ "   " ]),
        { code: "blank_description", field: "payments", payment_index: 0 }
      ]
    ]

    assert_table(bypassed_batches) do |label, batch, expected|
      actual = begin
        BulkPayments::Poster.call(batch)
        :no_error
      rescue BulkPayments::Error => e
        { code: e.code, field: e.field, payment_index: e.payment_index }.compact
      end
      [ label, expected, actual ]
    end
  end

  test "preserves global double-entry conservation and trigger purity across multi-party transfers" do
    firms = Array.new(5) { |i| create_firm!(name: "Firm #{i}", opening_balance_cents: 100_000 * (i + 1)) }
    total_opening = firms.sum(&:opening_balance_cents)

    batches = [
      [ firms[0], [ [ firms[1], 25_000 ], [ firms[2], 30_000 ], [ firms[1], 5_000 ] ] ],
      [ firms[1], [ [ firms[3], 110_000 ], [ firms[4], 15_000 ] ] ],
      [ firms[4], [ [ firms[0], 250_000 ], [ firms[2], 75_123 ] ] ],
      [ firms[2], [ [ firms[0], 10_000 ], [ firms[3], 10_000 ] ] ]
    ]

    batches.each_with_index do |(sender, legs), idx|
      BulkPayments::Poster.call(
        BulkPayments::PayloadParser::ParsedBatch.new(
          payer_firm_uuid: sender.uuid,
          payee_firm_uuids: legs.map { |f, _| f.uuid },
          amounts_cents: legs.map { |_, amt| amt },
          descriptions: legs.map.with_index { |_, j| "Batch #{idx} Leg #{j}" }
        )
      )
    end

    all_payments = fetch_all_payments
    reconstructed_balances = firms.to_h do |firm|
      incoming = all_payments.select { |p| p[:payee_firm_id] == firm.id }.sum { |p| p[:amount_cents] }
      outgoing = all_payments.select { |p| p[:payer_firm_id] == firm.id }.sum { |p| p[:amount_cents] }
      [ firm.id, firm.opening_balance_cents + incoming - outgoing ]
    end
    view_balances = firms.to_h { |firm| [ firm.id, firm_balance_cents(firm.id) ] }

    sender_conservation = firms.to_h do |sender|
      ruby_outgoing = all_payments.select { |p| p[:payer_firm_id] == sender.id }.sum { |p| p[:amount_cents] }
      recipient_credits_from_sender = admin_connection.exec_params(
        "SELECT COALESCE(SUM(amount_cents::numeric), 0) AS s FROM public.payments WHERE payer_firm_id = $1 AND payee_firm_id IS NOT NULL",
        [ sender.id ]
      ).first["s"].to_i
      [ sender.id, ruby_outgoing == recipient_credits_from_sender ]
    end

    payment_triggers = admin_connection.exec(<<~SQL).map { |r| r["tgname"] }
      SELECT tgname
      FROM pg_catalog.pg_trigger
      WHERE tgrelid = 'public.payments'::regclass AND NOT tgisinternal
      ORDER BY tgname
    SQL

    assert_equal(
      {
        sender_debits_equal_recipient_credits: firms.to_h { |f| [ f.id, true ] },
        view_balances: reconstructed_balances,
        global_sum: total_opening,
        payment_triggers: %w[trg_payments_immutability trg_payments_no_truncate]
      },
      {
        sender_debits_equal_recipient_credits: sender_conservation,
        view_balances: view_balances,
        global_sum: view_balances.values.sum,
        payment_triggers: payment_triggers
      }
    )
  end
end

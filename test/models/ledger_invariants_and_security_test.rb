# frozen_string_literal: true

require "test_helper"

class LedgerInvariantsAndSecurityTest < ActiveSupport::TestCase
  test "runtime role can create firms with valid opening funds and update only firm name" do
    firm = create_firm!(name: "Original Name", opening_balance_cents: 25_000)
    assert_equal "Original Name", firm.name
    assert_equal 25_000, firm.opening_balance_cents
    assert_equal 25_000, firm_balance_cents(firm.uuid)

    firm.update!(name: "Updated Firm Name")
    reloaded = FirmDescription.find(firm.id)
    assert_equal "Updated Firm Name", reloaded.name
    assert_equal 25_000, reloaded.opening_balance_cents

    view_row = Firm.find(firm.id)
    assert_equal "Updated Firm Name", view_row.name
    assert_equal 25_000, BigDecimal(view_row.balance_cents.to_s)
  end

  test "runtime role cannot create firms with negative opening balance or blank name" do
    conn = ApplicationRecord.lease_connection

    assert_raises(ActiveRecord::StatementInvalid) do
      conn.exec_query(
        "INSERT INTO public.firm_descriptions (name, opening_balance_cents) VALUES ($1, $2)",
        "NegativeOpeningTest",
        [ "Bad Firm", -1 ]
      )
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      conn.exec_query(
        "INSERT INTO public.firm_descriptions (name, opening_balance_cents) VALUES ($1, $2)",
        "BlankNameTest",
        [ "   \t\n  ", 0 ]
      )
    end
  end

  test "runtime role is strictly forbidden from updating immutable firm columns, deleting firms, touching payments directly, or altering schema" do
    firm1 = create_firm!(name: "Firm One", opening_balance_cents: 50_000)
    firm2 = create_firm!(name: "Firm Two", opening_balance_cents: 10_000)
    conn = ApplicationRecord.lease_connection

    err_opening = assert_raises(ActiveRecord::StatementInvalid) do
      conn.exec_query(
        "UPDATE public.firm_descriptions SET opening_balance_cents = 999999 WHERE id = $1",
        "UpdateOpeningDenied",
        [ firm1.id ]
      )
    end
    assert_kind_of PG::InsufficientPrivilege, err_opening.cause

    err_uuid = assert_raises(ActiveRecord::StatementInvalid) do
      conn.exec_query(
        "UPDATE public.firm_descriptions SET uuid = $1::uuid WHERE id = $2",
        "UpdateUuidDenied",
        [ "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", firm1.id ]
      )
    end
    assert_kind_of PG::InsufficientPrivilege, err_uuid.cause

    err_id = assert_raises(ActiveRecord::StatementInvalid) do
      conn.exec_query(
        "UPDATE public.firm_descriptions OVERRIDING SYSTEM VALUE SET id = 999 WHERE id = $1",
        "UpdateIdDenied",
        [ firm1.id ]
      )
    end
    assert_includes [ PG::InsufficientPrivilege, PG::GeneratedAlways, PG::SyntaxError ], err_id.cause.class

    err_created_at = assert_raises(ActiveRecord::StatementInvalid) do
      conn.exec_query(
        "UPDATE public.firm_descriptions SET created_at = NOW() WHERE id = $1",
        "UpdateCreatedAtDenied",
        [ firm1.id ]
      )
    end
    assert_kind_of PG::InsufficientPrivilege, err_created_at.cause

    err_del_firm = assert_raises(ActiveRecord::StatementInvalid) do
      conn.exec_query("DELETE FROM public.firm_descriptions WHERE id = $1", "DeleteFirmDenied", [ firm1.id ])
    end
    assert_kind_of PG::InsufficientPrivilege, err_del_firm.cause

    [
      "SELECT * FROM public.payments",
      "INSERT INTO public.payments (payer_firm_id, payee_firm_id, amount_cents, description) VALUES (#{firm1.id}, #{firm2.id}, 100, 'Bypass')",
      "UPDATE public.payments SET amount_cents = 1",
      "DELETE FROM public.payments",
      "TRUNCATE public.payments"
    ].each do |forbidden_sql|
      err = assert_raises(ActiveRecord::StatementInvalid, "Expected InsufficientPrivilege for: #{forbidden_sql}") do
        conn.execute(forbidden_sql)
      end
      assert_kind_of PG::InsufficientPrivilege, err.cause
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      conn.execute("DELETE FROM public.firms")
    end

    [
      "CREATE TABLE public.rogue_table (id int)",
      "DROP VIEW public.firms",
      "ALTER TABLE public.firm_descriptions ADD COLUMN hacked boolean"
    ].each do |ddl_sql|
      err = assert_raises(ActiveRecord::StatementInvalid, "Expected privilege error for DDL: #{ddl_sql}") do
        conn.execute(ddl_sql)
      end
      assert_kind_of PG::Error, err.cause
    end
  end

  test "immutability triggers block updates/deletes on payments and immutable firm columns even for privileged roles" do
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

    payment_id = fetch_all_payments.first[:id]

    assert_raises(PG::ObjectNotInPrerequisiteState) do
      admin_connection.exec_params("UPDATE public.payments SET amount_cents = 1 WHERE id = $1", [ payment_id ])
    end

    assert_raises(PG::ObjectNotInPrerequisiteState) do
      admin_connection.exec_params("UPDATE public.payments SET description = 'Tampered' WHERE id = $1", [ payment_id ])
    end

    assert_raises(PG::ObjectNotInPrerequisiteState) do
      admin_connection.exec_params("DELETE FROM public.payments WHERE id = $1", [ payment_id ])
    end

    assert_raises(PG::ObjectNotInPrerequisiteState) do
      admin_connection.exec("TRUNCATE public.payments")
    end

    assert_raises(PG::ObjectNotInPrerequisiteState) do
      admin_connection.exec_params("UPDATE public.firm_descriptions SET opening_balance_cents = 999999 WHERE id = $1", [ payer.id ])
    end

    assert_raises(PG::ObjectNotInPrerequisiteState) do
      admin_connection.exec_params("DELETE FROM public.firm_descriptions WHERE id = $1", [ payee.id ])
    end
  end

  test "post_bulk_payments is VOLATILE, SECURITY DEFINER, and rejects REPEATABLE READ, SERIALIZABLE, and READ ONLY transactions" do
    fn_meta = admin_connection.exec(<<~SQL).first
      SELECT p.provolatile, p.prosecdef, pg_catalog.pg_get_userbyid(p.proowner) AS owner_name, p.proconfig
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'post_bulk_payments'
    SQL

    assert_equal "v", fn_meta["provolatile"], "Function must be VOLATILE"
    assert_equal "t", fn_meta["prosecdef"], "Function must be SECURITY DEFINER"
    assert_equal "ledger_definer", fn_meta["owner_name"], "Function must be owned by dedicated definer role"
    assert_includes fn_meta["proconfig"].to_s, "search_path=pg_catalog, pg_temp"

    payer = create_firm!(name: "Iso Payer", opening_balance_cents: 10_000)
    payee = create_firm!(name: "Iso Payee", opening_balance_cents: 0)
    conn = ApplicationRecord.lease_connection

    %i[repeatable_read serializable].each do |bad_isolation|
      err = assert_raises(ActiveRecord::StatementInvalid) do
        conn.transaction(isolation: bad_isolation, joinable: false) do
          conn.exec_query(
            "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100]::int4[], ARRAY['Test']::text[])",
            "BadIsolationTest",
            [ payer.uuid, payee.uuid ]
          )
        end
      end
      assert_equal "25001", err.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      assert_equal "invalid_transaction_isolation", err.cause.result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)
    end

    err_ro = assert_raises(ActiveRecord::StatementInvalid) do
      conn.transaction(isolation: :read_committed, joinable: false) do
        conn.execute("SET LOCAL transaction_read_only = on")
        conn.exec_query(
          "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100]::int4[], ARRAY['Test']::text[])",
          "ReadOnlyTest",
          [ payer.uuid, payee.uuid ]
        )
      end
    end
    assert_equal "25006", err_ro.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
    assert_equal "read_only_transaction", err_ro.cause.result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)

    assert_empty fetch_all_payments
  end

  test "post_bulk_payments validates its own SQL arguments directly when called outside Rails HTTP validation" do
    payer = create_firm!(name: "Arg Payer", opening_balance_cents: 50_000)
    payee = create_firm!(name: "Arg Payee", opening_balance_cents: 0)
    conn = ApplicationRecord.lease_connection

    invalid_sql_calls = [
      [ "SELECT public.post_bulk_payments(NULL::uuid, ARRAY[$1::uuid], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payee.uuid ], "null_payer_firm_uuid" ],
      [ "SELECT public.post_bulk_payments($1::uuid, NULL::uuid[], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payer.uuid ], "null_payment_arrays" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[]::uuid[], ARRAY[]::int4[], ARRAY[]::text[])", [ payer.uuid ], "invalid_batch_size" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100, 200]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ], "mismatched_array_lengths" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[[$2::uuid]], ARRAY[[100]]::int4[], ARRAY[['ok']]::text[])", [ payer.uuid, payee.uuid ], "invalid_array_dimensions" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ('[2:2]={' || $2::text || '}')::uuid[], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ], "invalid_array_dimensions" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[NULL::uuid], ARRAY[100]::int4[], ARRAY['ok']::text[])", [ payer.uuid ], "null_payee_firm_uuid" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[0]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ], "invalid_amount_cents" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[-50]::int4[], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ], "invalid_amount_cents" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[NULL::int4], ARRAY['ok']::text[])", [ payer.uuid, payee.uuid ], "invalid_amount_cents" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100]::int4[], ARRAY['   ']::text[])", [ payer.uuid, payee.uuid ], "blank_description" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[$2::uuid], ARRAY[100]::int4[], ARRAY[NULL::text])", [ payer.uuid, payee.uuid ], "blank_description" ],
      [ "SELECT public.post_bulk_payments($1::uuid, ARRAY[$1::uuid], ARRAY[100]::int4[], ARRAY['Self']::text[])", [ payer.uuid ], "self_payment" ]
    ]

    invalid_sql_calls.each do |sql, binds, expected_detail|
      err = assert_raises(ActiveRecord::StatementInvalid, "Expected failure (#{expected_detail}) for SQL: #{sql}") do
        conn.transaction(isolation: :read_committed, joinable: false) do
          conn.exec_query(sql, "DirectSqlArgTest", binds)
        end
      end
      actual_detail = err.cause.result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)
      assert_equal expected_detail, actual_detail, "Unexpected detail for #{sql}"
    end

    assert_empty fetch_all_payments
  end

  test "Poster translates Layer 2 PostgreSQL safeguard rejections into BulkPayments::Error doors when Layer 1 is bypassed" do
    payer = create_firm!(name: "Safeguard Payer", opening_balance_cents: 50_000)
    bypassed_batch = BulkPayments::PayloadParser::ParsedBatch.new(
      payer_firm_uuid: payer.uuid,
      payee_firm_uuids: [ payer.uuid ],
      amounts_cents: [ 500 ],
      descriptions: [ "Direct Poster call bypassing PayloadParser" ]
    )

    err = assert_raises(BulkPayments::Error) do
      BulkPayments::Poster.call(bypassed_batch)
    end

    assert_equal "self_payment", err.code
    assert_equal "payments[0].payee_firm_uuid", err.field
    assert_equal 0, err.payment_index
    assert_empty fetch_all_payments
  end

  test "verifies global accounting conservation invariants across multi-party transfers" do
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

    # Invariant 1: For each sender, total outgoing equals total recipient credits originating from that sender.
    firms.each do |sender|
      outgoing_from_sender = all_payments.select { |p| p[:payer_firm_id] == sender.id }.sum { |p| p[:amount_cents] }
      credits_from_sender = admin_connection.exec_params(
        "SELECT COALESCE(SUM(amount_cents::numeric), 0) AS s FROM public.payments WHERE payer_firm_id = $1",
        [ sender.id ]
      ).first["s"].to_i
      assert_equal outgoing_from_sender, credits_from_sender
    end

    # Invariant 2: Raw history + opening funds reproduces every firm's view balance,
    # and global sum of derived balances equals global sum of opening funds.
    sum_of_derived_balances = 0
    firms.each do |firm|
      incoming = all_payments.select { |p| p[:payee_firm_id] == firm.id }.sum { |p| p[:amount_cents] }
      outgoing = all_payments.select { |p| p[:payer_firm_id] == firm.id }.sum { |p| p[:amount_cents] }
      expected_balance = firm.opening_balance_cents + incoming - outgoing
      actual_balance = firm_balance_cents(firm.id).to_i

      assert_equal expected_balance, actual_balance
      sum_of_derived_balances += actual_balance
    end

    assert_equal total_opening, sum_of_derived_balances

    # Invariant 3: Only immutability guard triggers exist on `payments` (zero hidden balance-snapshot triggers).
    triggers = admin_connection.exec(<<~SQL).map { |r| r["tgname"] }
      SELECT tgname
      FROM pg_catalog.pg_trigger
      WHERE tgrelid = 'public.payments'::regclass AND NOT tgisinternal
      ORDER BY tgname
    SQL
    assert_equal %w[trg_payments_immutability trg_payments_no_truncate], triggers
  end
end

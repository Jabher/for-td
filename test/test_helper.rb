# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module LedgerTestHelpers
  # Separate `ledger_admin` connection used strictly in tests to reset fixture tables
  # and inspect `public.payments`, which `ledger_runtime` has zero privileges on.
  def admin_connection
    @admin_connection ||= begin
      cfg = ActiveRecord::Base.connection_db_config.configuration_hash.merge(
        username: ENV.fetch("DB_ADMIN_USER", "ledger_admin"),
        password: ENV.fetch("DB_ADMIN_PASSWORD", "ledger_admin_secret")
      )
      PG.connect(
        host: cfg[:host],
        port: cfg[:port],
        dbname: cfg[:database],
        user: cfg[:username],
        password: cfg[:password]
      ).tap { |c| c.set_notice_processor { } }
    end
  end

  def close_admin_connection
    return unless defined?(@admin_connection) && @admin_connection

    @admin_connection.close unless @admin_connection.finished?
    @admin_connection = nil
  end

  def reset_ledger_state!
    admin_connection.exec(<<~SQL)
      ALTER TABLE public.payments DISABLE TRIGGER USER;
      ALTER TABLE public.firm_descriptions DISABLE TRIGGER USER;
      TRUNCATE TABLE public.payments, public.firm_descriptions RESTART IDENTITY;
      ALTER TABLE public.firm_descriptions ENABLE TRIGGER USER;
      ALTER TABLE public.payments ENABLE TRIGGER USER;
    SQL
  end

  def create_firm!(name:, opening_balance_cents:, uuid: nil)
    attrs = { name: name, opening_balance_cents: opening_balance_cents }
    attrs[:uuid] = uuid if uuid
    record = FirmDescription.create!(attrs)
    FirmDescription.find(record.id)
  end

  def firm_balance_cents(uuid_or_id)
    firm = uuid_or_id.is_a?(Integer) ? Firm.find(uuid_or_id) : Firm.find_by!(uuid: uuid_or_id)
    decimal = BigDecimal(firm.balance_cents.to_s)
    decimal.frac.zero? ? decimal.to_i : decimal
  end

  def fetch_all_payments
    admin_connection.exec(<<~SQL).map do |row|
      SELECT id, payer_firm_id, payee_firm_id, amount_cents, description, created_at
      FROM public.payments
      ORDER BY id ASC
    SQL
      {
        id: row["id"].to_i,
        payer_firm_id: row["payer_firm_id"].to_i,
        payee_firm_id: row["payee_firm_id"].to_i,
        amount_cents: row["amount_cents"].to_i,
        description: row["description"],
        created_at: row["created_at"]
      }
    end
  end

  def count_sql_queries
    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { queries += 1 }
    result = yield
    [ result, queries ]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def assert_table(rows)
    failures = rows.filter_map.with_index do |row, idx|
      label, expected, actual = yield(row)
      next if expected == actual

      "[row #{idx} #{label}] expected #{expected.inspect}, got #{actual.inspect}"
    rescue StandardError => e
      "[row #{idx} #{row.inspect}] unexpected #{e.class}: #{e.message}"
    end

    assert_empty failures, failures.join("\n")
  end

  def capture_pg_error(include_target: true)
    yield
    :no_error
  rescue ActiveRecord::StatementInvalid => e
    extract_pg_diag(e.cause, include_target: include_target)
  rescue PG::Error => e
    extract_pg_diag(e, include_target: include_target)
  end

  private

    def extract_pg_diag(pg_error, include_target:)
      return pg_error.class.name unless pg_error.is_a?(PG::Error) && pg_error.result

      res = pg_error.result
      sqlstate = res.error_field(PG::Result::PG_DIAG_SQLSTATE)
      return sqlstate unless include_target

      target = res.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) ||
               res.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)
      [ sqlstate, target ]
    end
end

module ActiveSupport
  class TestCase
    # `BulkPayments::Poster` opens top-level `BEGIN ISOLATION LEVEL READ COMMITTED` transactions
    # (`joinable: false`), which cannot nest inside transactional test savepoints.
    self.use_transactional_tests = false

    include LedgerTestHelpers

    setup do
      reset_ledger_state!
    end

    teardown do
      close_admin_connection
    end
  end
end

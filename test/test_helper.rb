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
      )
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
    firm = if uuid_or_id.is_a?(Integer)
      Firm.find(uuid_or_id)
    else
      Firm.find_by!(uuid: uuid_or_id)
    end
    BigDecimal(firm.balance_cents.to_s)
  end

  def fetch_all_payments
    res = admin_connection.exec(<<~SQL)
      SELECT id, payer_firm_id, payee_firm_id, amount_cents, description, created_at
      FROM public.payments
      ORDER BY id ASC
    SQL
    res.map do |row|
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

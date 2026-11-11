# frozen_string_literal: true

# ActiveRecord's `pg_dump` uses `--no-owner --no-privileges` when writing `db/structure.sql`.
# Appending an explicit `SELECT public.apply_ledger_security();` statement to `db/structure.sql`
# ensures that recreating a fresh database from `db/structure.sql` (e.g. `db:schema:load`,
# `db:test:prepare`, or parallel test database setup) restores identical SECURITY DEFINER
# ownership and strict least-privilege grants for `ledger_runtime`.
Rake::Task["db:schema:dump"].enhance do
  structure_path = Rails.root.join("db/structure.sql")
  next unless structure_path.exist?

  content = structure_path.read
  security_bootstrap = <<~SQL
    -- Restore SECURITY DEFINER ownership and least-privilege runtime grants
    SELECT public.apply_ledger_security();
    REVOKE ALL ON FUNCTION public.apply_ledger_security() FROM PUBLIC, ledger_runtime;
  SQL

  unless content.include?("SELECT public.apply_ledger_security();")
    structure_path.write("#{content.rstrip}\n\n#{security_bootstrap}\n")
  end
end

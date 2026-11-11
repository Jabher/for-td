# frozen_string_literal: true

# ActiveRecord's `db:schema:dump` runs `pg_dump --no-owner --no-privileges`, stripping
# `SECURITY DEFINER` ownership (`ledger_definer`) and `ledger_runtime` column/table ACLs.
# Appending `SELECT public.apply_ledger_security()` ensures `db:schema:load` recreates
# the exact least-privilege security posture on fresh databases.
Rake::Task["db:schema:dump"].enhance do
  structure_path = Rails.root.join("db/structure.sql")
  next unless structure_path.exist?

  content = structure_path.read
  security_bootstrap = <<~SQL
    SELECT public.apply_ledger_security();
    REVOKE ALL ON FUNCTION public.apply_ledger_security() FROM PUBLIC, ledger_runtime;
  SQL

  unless content.include?("SELECT public.apply_ledger_security();")
    structure_path.write("#{content.rstrip}\n\n#{security_bootstrap}\n")
  end
end

# frozen_string_literal: true

[
  {
    uuid: "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41",
    name: "Pinecrest CPA Group",
    opening_balance_cents: 5_000_000
  },
  {
    uuid: "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10",
    name: "Lopez Bookkeeping",
    opening_balance_cents: 50_000
  },
  {
    uuid: "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25",
    name: "Nair Tax Services",
    opening_balance_cents: 200_000
  }
].each do |attrs|
  existing = FirmDescription.find_by(uuid: attrs[:uuid])
  if existing
    existing.update!(name: attrs[:name]) if existing.name != attrs[:name]
  else
    FirmDescription.create!(attrs)
  end
end

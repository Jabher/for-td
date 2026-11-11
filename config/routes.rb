# frozen_string_literal: true

Rails.application.routes.draw do
  # POST /bulk_payments is the sole endpoint in this project.
  post "bulk_payments", to: "bulk_payments#create"
end

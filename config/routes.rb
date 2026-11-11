# frozen_string_literal: true

Rails.application.routes.draw do
  post "bulk_payments", to: "bulk_payments#create"
end

# frozen_string_literal: true

class ApplicationController < ActionController::API
  rescue_from StandardError, with: :render_unexpected_error
  rescue_from BulkPayments::Error, with: :render_domain_error

  private

    def render_domain_error(error)
      render json: error.to_payload, status: :unprocessable_content
    end

    def render_unexpected_error(exception)
      Rails.logger.error(
        "[UnhandledError] #{exception.class}: #{exception.message}\n" \
        "#{Array(exception.backtrace).first(25).join("\n")}"
      )

      render json: {
        error: {
          code: "internal_error",
          what: "An unexpected internal error occurred while processing the request.",
          why: "The server encountered an unhandled failure and safely aborted the operation without persisting changes.",
          how_to_fix: "Retry the request later or contact support with the X-Request-Id response header if the issue persists."
        }
      }, status: :internal_server_error
    end
end

# frozen_string_literal: true

# ActionDispatch's default JSON parser raises `ActionDispatch::Http::Parameters::ParseError`
# (HTTP 400) before routing. Clearing `parameter_parsers` hands raw request bytes to
# `BulkPayments::PayloadParser` so malformed JSON returns HTTP 422 with an RFC 8259 door.
ActionDispatch::Request.parameter_parsers = {}

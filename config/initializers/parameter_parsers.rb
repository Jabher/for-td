# frozen_string_literal: true

# Disable ActionDispatch's implicit JSON parameter parser so JSON bodies are
# parsed once and validated strictly by BulkPayments::PayloadParser, allowing
# malformed JSON to return HTTP 422 with a detailed RFC 8259 syntax explanation
# rather than ActionDispatch::Http::Parameters::ParseError (HTTP 400).
ActionDispatch::Request.parameter_parsers = {}

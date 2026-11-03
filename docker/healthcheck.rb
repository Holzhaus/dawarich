#!/usr/local/bin/ruby --disable-gems
# frozen_string_literal: true

# Container healthcheck for the Distroless image, which has no shell or wget:
# exits 0 when /api/v1/health reports "status": "ok".
require 'net/http'

port = ENV.fetch('RAILS_PORT', '3000')

begin
  response = Net::HTTP.start('127.0.0.1', port, open_timeout: 5, read_timeout: 5) do |http|
    http.get('/api/v1/health')
  end
  exit(response.body.to_s.match?(/"status"\s*:\s*"ok"/) ? 0 : 1)
rescue StandardError => e
  warn "healthcheck failed: #{e.class}: #{e.message}"
  exit 1
end

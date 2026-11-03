# frozen_string_literal: true

require 'net/http'

# HTTP client for the renderer sidecar (docker/Dockerfile, target "renderer";
# vendor/poster_renderer/server.mjs). The Distroless app image has no Node,
# Mesa or rsvg-convert, so poster and achievement image rendering go to the
# sidecar when RENDERER_URL is set. Without it, the services run their local
# command instead (development, tests).
module RendererSidecar
  class Error < StandardError; end

  OPEN_TIMEOUT = 5

  module_function

  def configured?
    url.present?
  end

  def url
    ENV['RENDERER_URL'].presence
  end

  # Returns the response body. Raises Error on a non-2xx response; timeouts
  # surface as Net::OpenTimeout / Net::ReadTimeout (both Timeout::Error).
  def post(path, body, content_type:, timeout:)
    uri = URI.join("#{url.chomp('/')}/", path.delete_prefix('/'))
    request = Net::HTTP::Post.new(uri, 'Content-Type' => content_type)
    request.body = body

    response = Net::HTTP.start(
      uri.host, uri.port,
      use_ssl: uri.scheme == 'https', open_timeout: OPEN_TIMEOUT, read_timeout: timeout, write_timeout: timeout
    ) { |http| http.request(request) }
    return response.body if response.is_a?(Net::HTTPSuccess)

    raise Error, "#{response.code} #{error_message(response.body)}"
  end

  def error_message(body)
    parsed = JSON.parse(body.to_s)
    (parsed['error'].presence if parsed.is_a?(Hash)) || body.to_s.truncate(500)
  rescue JSON::ParserError
    body.to_s.truncate(500)
  end
end

# frozen_string_literal: true

require "test_helper"
require "net/http"

describe "Net::HTTP Patch" do
  before do
    # Apply the patch
    OutboundHttpLogger::Patches::NetHttpPatch.apply!
  end

  describe "when logging is enabled" do
    before do
      OutboundHttpLogger.enable!
    end

    it "logs successful GET requests" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: '{"users": []}', headers: { 'Content-Type' => 'application/json' })

      uri      = URI('https://api.example.com/users')
      response = Net::HTTP.get_response(uri)

      _(response.code).must_equal "200"

      log = assert_request_logged(:get, "https://api.example.com/users", 200)
      _(log.response_body).must_equal '{"users":[]}'
      _(log.duration_ms).must_be :>, 0
    end

    it "logs POST requests with request body" do
      stub_request(:post, "https://api.example.com/users")
        .with(body: '{"name": "John"}', headers: { 'Content-Type' => 'application/json' })
        .to_return(status: 201, body: '{"id": 1, "name": "John"}', headers: { 'Content-Type' => 'application/json' })

      uri          = URI('https://api.example.com/users')
      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request                 = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body            = '{"name": "John"}'

      response = http.request(request)

      _(response.code).must_equal "201"

      log = assert_request_logged(:post, "https://api.example.com/users", 201)
      _(log.request_body).must_equal '{"name":"John"}'
      _(log.response_body).must_equal '{"id":1,"name":"John"}'
    end

    it "logs requests with headers" do
      stub_request(:get, "https://api.example.com/protected")
        .with(headers: { 'Authorization' => 'Bearer token123' })
        .to_return(status: 200, body: '{"data": "secret"}', headers: { 'Content-Type' => 'application/json' })

      uri          = URI('https://api.example.com/protected')
      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request                  = Net::HTTP::Get.new(uri)
      request['Authorization'] = 'Bearer token123'

      response = http.request(request)

      _(response.code).must_equal "200"

      log = assert_request_logged(:get, "https://api.example.com/protected", 200)
      _(log.request_headers['authorization']).must_equal '[FILTERED]'
    end

    it "logs failed requests" do
      stub_request(:get, "https://api.example.com/notfound")
        .to_return(status: 404, body: '{"error": "Not found"}', headers: { 'Content-Type' => 'application/json' })

      uri      = URI('https://api.example.com/notfound')
      response = Net::HTTP.get_response(uri)

      _(response.code).must_equal "404"

      log = assert_request_logged(:get, "https://api.example.com/notfound", 404)
      _(log.response_body).must_equal '{"error":"Not found"}'
    end

    it "skips excluded URLs" do
      stub_request(:get, "https://api.example.com/health")
        .to_return(status: 200, body: 'OK')

      uri      = URI('https://api.example.com/health')
      response = Net::HTTP.get_response(uri)

      _(response.code).must_equal "200"
      assert_no_request_logged
    end

    it "skips excluded content types" do
      stub_request(:get, "https://api.example.com/page")
        .to_return(status: 200, body: '<html></html>', headers: { 'Content-Type' => 'text/html' })

      uri      = URI('https://api.example.com/page')
      response = Net::HTTP.get_response(uri)

      _(response.code).must_equal "200"
      assert_no_request_logged
    end

    it "handles network errors gracefully" do
      stub_request(:get, "https://api.example.com/error")
        .to_raise(SocketError.new("Connection failed"))

      uri = URI('https://api.example.com/error')

      _(proc { Net::HTTP.get_response(uri) }).must_raise SocketError

      # Should log the error
      log = assert_request_logged(:get, "https://api.example.com/error", 0)
      _(log.response_body).must_include "SocketError"
    end

    it "prevents infinite recursion" do
      # This test ensures that our patch doesn't cause infinite loops
      stub_request(:get, "https://api.example.com/test")
        .to_return(status: 200, body: 'OK')

      uri = URI('https://api.example.com/test')

      # Make multiple requests to ensure no recursion issues
      3.times do
        response = Net::HTTP.get_response(uri)

        _(response.code).must_equal "200"
      end

      # Should have 3 separate log entries
      logs = OutboundHttpLogger::Models::OutboundRequestLog.where(url: "https://api.example.com/test")

      _(logs.count).must_equal 3
    end
  end

  describe "when logging is disabled" do
    before do
      OutboundHttpLogger.disable!
    end

    it "does not log requests when disabled" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: '{"users": []}')

      uri      = URI('https://api.example.com/users')
      response = Net::HTTP.get_response(uri)

      _(response.code).must_equal "200"
      assert_no_request_logged
    end
  end
end

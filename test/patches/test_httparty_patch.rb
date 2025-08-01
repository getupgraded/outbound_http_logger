# frozen_string_literal: true

require 'test_helper'
require 'httparty'

# NOTE: HTTParty patch has been removed as HTTParty uses Net::HTTP internally.
# These tests are kept for reference and to verify that HTTParty requests
# are still logged correctly via the Net::HTTP patch.
describe 'HTTParty Integration (via Net::HTTP patch)' do
  before do
    # Apply Net::HTTP patch instead of HTTParty patch
    OutboundHTTPLogger::Patches::NetHTTPPatch.apply!
  end

  describe 'when logging is enabled' do
    it 'logs successful GET requests' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/users')
          .to_return(status: 200, body: '{"users": []}', headers: { 'Content-Type' => 'application/json' })

        response = HTTParty.get('https://api.example.com/users')

        _(response.code).must_equal 200

        log = assert_request_logged(:get, 'https://api.example.com/users', 200)
        _(log.response_body).must_equal '{"users":[]}'
        _(log.duration_ms).must_be :>, 0
        # Verify that the library is detected as HTTParty
        _(log.metadata['library']).must_equal 'httparty'
      end
    end

    it 'logs POST requests with request body' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:post, 'https://api.example.com/users')
          .with(body: '{"name": "John"}', headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 201, body: '{"id": 1, "name": "John"}', headers: { 'Content-Type' => 'application/json' })

        response = HTTParty.post('https://api.example.com/users', body: '{"name": "John"}', headers: { 'Content-Type' => 'application/json' })

        _(response.code).must_equal 201

        log = assert_request_logged(:post, 'https://api.example.com/users', 201)
        _(log.request_body).must_equal '{"name":"John"}'
        _(log.response_body).must_equal '{"id":1,"name":"John"}'
      end
    end

    it 'logs requests with headers' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/protected')
          .with(headers: { 'Authorization' => 'Bearer token123' })
          .to_return(status: 200, body: '{"data": "secret"}', headers: { 'Content-Type' => 'application/json' })

        response = HTTParty.get('https://api.example.com/protected', headers: { 'Authorization' => 'Bearer token123' })

        _(response.code).must_equal 200

        log = assert_request_logged(:get, 'https://api.example.com/protected', 200)
        _(log.request_headers['authorization']).must_equal '[FILTERED]'
      end
    end

    it 'logs failed requests' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/notfound')
          .to_return(status: 404, body: '{"error": "Not found"}', headers: { 'Content-Type' => 'application/json' })

        response = HTTParty.get('https://api.example.com/notfound')

        _(response.code).must_equal 404

        log = assert_request_logged(:get, 'https://api.example.com/notfound', 404)
        _(log.response_body).must_equal '{"error":"Not found"}'
      end
    end

    it 'skips excluded URLs' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/health')
          .to_return(status: 200, body: 'OK')

        response = HTTParty.get('https://api.example.com/health')

        _(response.code).must_equal 200
        assert_no_request_logged
      end
    end

    it 'skips excluded content types' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/page')
          .to_return(status: 200, body: '<html></html>', headers: { 'Content-Type' => 'text/html' })

        response = HTTParty.get('https://api.example.com/page')

        _(response.code).must_equal 200
        assert_no_request_logged
      end
    end

    it 'handles network errors gracefully' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/error')
          .to_raise(SocketError.new('Connection failed'))

        _(proc { HTTParty.get('https://api.example.com/error') }).must_raise SocketError

        log = assert_request_logged(:get, 'https://api.example.com/error', 0)
        _(log.response_body).must_include 'SocketError'
      end
    end

    it 'prevents infinite recursion' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/test')
          .to_return(status: 200, body: 'OK')

        3.times do
          response = HTTParty.get('https://api.example.com/test')

          _(response.code).must_equal 200
        end

        logs = OutboundHTTPLogger::Models::OutboundRequestLog.where(url: 'https://api.example.com/test')

        _(logs.count).must_equal 3 # HTTParty requests are now logged only once via Net::HTTP patch
      end
    end
  end

  describe 'when logging is disabled' do
    before do
      OutboundHTTPLogger.disable!
    end

    after do
      # Reset to default state after disabling
      OutboundHTTPLogger.disable!
      OutboundHTTPLogger.clear_thread_data
    end

    it 'does not log requests when disabled' do
      stub_request(:get, 'https://api.example.com/users')
        .to_return(status: 200, body: '{"users": []}')

      response = HTTParty.get('https://api.example.com/users')

      _(response.code).must_equal 200
      assert_no_request_logged
    end
  end
end

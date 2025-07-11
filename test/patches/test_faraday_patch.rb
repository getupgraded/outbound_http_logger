# frozen_string_literal: true

require 'test_helper'
require 'faraday'

describe 'Faraday Patch' do
  before do
    OutboundHTTPLogger::Patches::FaradayPatch.apply!
  end

  describe 'when logging is enabled' do
    it 'logs successful GET requests' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/users')
          .to_return(status: 200, body: '{"users": []}', headers: { 'Content-Type' => 'application/json' })

        connection = Faraday.new
        response   = connection.get('https://api.example.com/users')

        _(response.status).must_equal 200

        log = assert_request_logged(:get, 'https://api.example.com/users', 200)
        _(log.response_body).must_equal '{"users":[]}'
        _(log.duration_ms).must_be :>, 0
      end
    end

    it 'logs POST requests with request body' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:post, 'https://api.example.com/users')
          .with(body: '{"name": "John"}', headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 201, body: '{"id": 1, "name": "John"}', headers: { 'Content-Type' => 'application/json' })

        connection = Faraday.new(headers: { 'Content-Type' => 'application/json' })
        response   = connection.post('https://api.example.com/users', '{"name": "John"}')

        _(response.status).must_equal 201

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

        connection = Faraday.new
        response   = connection.get('https://api.example.com/protected') do |req|
          req.headers['Authorization'] = 'Bearer token123'
        end

        _(response.status).must_equal 200

        log = assert_request_logged(:get, 'https://api.example.com/protected', 200)
        _(log.request_headers['authorization']).must_equal '[FILTERED]'
      end
    end

    it 'logs failed requests' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/notfound')
          .to_return(status: 404, body: '{"error": "Not found"}', headers: { 'Content-Type' => 'application/json' })

        connection = Faraday.new
        response   = connection.get('https://api.example.com/notfound')

        _(response.status).must_equal 404

        log = assert_request_logged(:get, 'https://api.example.com/notfound', 404)
        _(log.response_body).must_equal '{"error":"Not found"}'
      end
    end

    it 'skips excluded URLs' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/health')
          .to_return(status: 200, body: 'OK')

        connection = Faraday.new
        response   = connection.get('https://api.example.com/health')

        _(response.status).must_equal 200
        assert_no_request_logged
      end
    end

    it 'skips excluded content types' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/page')
          .to_return(status: 200, body: '<html></html>', headers: { 'Content-Type' => 'text/html' })

        connection = Faraday.new
        response   = connection.get('https://api.example.com/page')

        _(response.status).must_equal 200
        assert_no_request_logged
      end
    end

    it 'handles network errors gracefully' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/error')
          .to_raise(SocketError.new('Connection failed'))

        connection = Faraday.new

        _(proc { connection.get('https://api.example.com/error') }).must_raise Faraday::ConnectionFailed

        log = assert_request_logged(:get, 'https://api.example.com/error', 0)
        _(log.response_body).must_include 'SocketError'
      end
    end

    it 'prevents infinite recursion' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        stub_request(:get, 'https://api.example.com/test')
          .to_return(status: 200, body: 'OK')

        connection = Faraday.new
        3.times do
          response = connection.get('https://api.example.com/test')

          _(response.status).must_equal 200
        end

        logs = OutboundHTTPLogger::Models::OutboundRequestLog.where(url: 'https://api.example.com/test')

        _(logs.count).must_equal 6 # Faraday uses Net::HTTP, so each request is logged twice
      end
    end

    # NEW TESTS: Base URL + Relative Path scenarios (the missing coverage!)
    describe 'base URL with relative paths' do
      it 'logs requests with base URL and relative path' do
        OutboundHTTPLogger.with_configuration(enabled: true) do
          stub_request(:get, 'https://api.example.com/users')
            .to_return(status: 200, body: '{"users": []}', headers: { 'Content-Type' => 'application/json' })

          # This is the pattern that was missing from our tests!
          connection = Faraday.new('https://api.example.com')
          response = connection.get('/users') # Relative path

          _(response.status).must_equal 200

          log = assert_request_logged(:get, 'https://api.example.com/users', 200)
          _(log.response_body).must_equal '{"users":[]}'
        end
      end

      it 'logs requests with base URL and relative path without leading slash' do
        OutboundHTTPLogger.with_configuration(enabled: true) do
          stub_request(:get, 'https://api.example.com/posts')
            .to_return(status: 200, body: '{"posts": []}', headers: { 'Content-Type' => 'application/json' })

          connection = Faraday.new('https://api.example.com')
          response = connection.get('posts') # Relative path without leading slash

          _(response.status).must_equal 200

          log = assert_request_logged(:get, 'https://api.example.com/posts', 200)
          _(log.response_body).must_equal '{"posts":[]}'
        end
      end

      it 'logs POST requests with base URL and relative path' do
        OutboundHTTPLogger.with_configuration(enabled: true) do
          stub_request(:post, 'https://api.example.com/users')
            .with(body: '{"name": "Jane"}', headers: { 'Content-Type' => 'application/json' })
            .to_return(status: 201, body: '{"id": 2, "name": "Jane"}', headers: { 'Content-Type' => 'application/json' })

          connection = Faraday.new('https://api.example.com', headers: { 'Content-Type' => 'application/json' })
          response = connection.post('/users', '{"name": "Jane"}')

          _(response.status).must_equal 201

          log = assert_request_logged(:post, 'https://api.example.com/users', 201)
          _(log.request_body).must_equal '{"name":"Jane"}'
          _(log.response_body).must_equal '{"id":2,"name":"Jane"}'
        end
      end

      it 'handles complex base URLs with paths' do
        OutboundHTTPLogger.with_configuration(enabled: true) do
          # When base URL has a path and we use absolute path, it replaces the base path
          stub_request(:get, 'https://api.example.com/users')
            .to_return(status: 200, body: '{"users": []}', headers: { 'Content-Type' => 'application/json' })

          connection = Faraday.new('https://api.example.com/v1')
          response = connection.get('/users') # This replaces /v1 with /users

          _(response.status).must_equal 200

          log = assert_request_logged(:get, 'https://api.example.com/users', 200)
          _(log.response_body).must_equal '{"users":[]}'
        end
      end

      it 'handles base URLs with path appending (relative paths)' do
        OutboundHTTPLogger.with_configuration(enabled: true) do
          # When using relative paths (no leading slash), they append to the base URL
          stub_request(:get, 'https://api.example.com/v1/users')
            .to_return(status: 200, body: '{"users": []}', headers: { 'Content-Type' => 'application/json' })

          connection = Faraday.new('https://api.example.com/v1/') # Note trailing slash
          response = connection.get('users') # Relative path appends

          _(response.status).must_equal 200

          log = assert_request_logged(:get, 'https://api.example.com/v1/users', 200)
          _(log.response_body).must_equal '{"users":[]}'
        end
      end

      it 'handles OAuth-like flows with complex URL building' do
        OutboundHTTPLogger.with_configuration(enabled: true) do
          # Simulate an OAuth token request
          stub_request(:post, 'https://oauth.example.com/token')
            .with(
              body: 'grant_type=authorization_code&code=abc123&client_id=test',
              headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
            )
            .to_return(
              status: 200,
              body: '{"access_token": "token123", "token_type": "Bearer"}',
              headers: { 'Content-Type' => 'application/json' }
            )

          # This mimics how OAuth libraries often set up Faraday
          connection = Faraday.new('https://oauth.example.com') do |conn|
            conn.request :url_encoded
            conn.adapter Faraday.default_adapter
          end

          response = connection.post('/token') do |req|
            req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
            req.body = 'grant_type=authorization_code&code=abc123&client_id=test'
          end

          _(response.status).must_equal 200

          log = assert_request_logged(:post, 'https://oauth.example.com/token', 200)
          _(log.request_body).must_include 'grant_type=authorization_code'
          _(log.response_body).must_include 'access_token'
        end
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

      connection = Faraday.new
      response   = connection.get('https://api.example.com/users')

      _(response.status).must_equal 200
      assert_no_request_logged
    end
  end
end

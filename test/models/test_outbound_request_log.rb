# frozen_string_literal: true

require 'test_helper'

describe OutboundHttpLogger::Models::OutboundRequestLog do
  let(:model) { OutboundHttpLogger::Models::OutboundRequestLog }

  before do
    # Reset database adapter cache
    OutboundHttpLogger::Models::OutboundRequestLog.reset_adapter_cache!

    # Reset global configuration to default state
    config = OutboundHttpLogger.global_configuration
    config.enabled                = false
    config.excluded_urls          = [
      %r{https://o\d+\.ingest\..*\.sentry\.io},  # Sentry URLs
      %r{/health},                               # Health check endpoints
      %r{/ping}                                  # Ping endpoints
    ]
    config.excluded_content_types = [
      'text/html',
      'text/css',
      'text/javascript',
      'application/javascript',
      'image/',
      'video/',
      'audio/',
      'font/'
    ]
    config.sensitive_headers = %w[
      authorization
      cookie
      set-cookie
      x-api-key
      x-auth-token
      x-access-token
      bearer
    ]
    config.sensitive_body_keys = %w[
      password
      secret
      token
      key
      auth
      credential
      private
    ]
    config.max_body_size          = 10_000
    config.debug_logging          = false
    config.logger                 = nil

    # Clear all logs
    OutboundHttpLogger::Models::OutboundRequestLog.delete_all

    # Clear thread-local data
    OutboundHttpLogger.clear_thread_data
  end

  after do
    # Disable logging
    OutboundHttpLogger.disable!

    # Clear thread-local data
    OutboundHttpLogger.clear_thread_data
  end

  describe 'validations' do
    it 'requires http_method' do
      log = model.new(url: 'https://example.com', status_code: 200)

      _(log.valid?).must_equal false
      _(log.errors[:http_method]).must_include "can't be blank"
    end

    it 'requires url' do
      log = model.new(http_method: 'GET', status_code: 200)

      _(log.valid?).must_equal false
      _(log.errors[:url]).must_include "can't be blank"
    end

    it 'requires status_code' do
      log = model.new(http_method: 'GET', url: 'https://example.com')

      _(log.valid?).must_equal false
      _(log.errors[:status_code]).must_include "can't be blank"
    end

    it 'requires status_code to be an integer' do
      log = model.new(http_method: 'GET', url: 'https://example.com', status_code: 'not_a_number')

      _(log.valid?).must_equal false
      _(log.errors[:status_code]).must_include 'is not a number'
    end
  end

  describe 'scopes' do
    before do
      # Create test data
      @success_log = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/users',
        status_code: 200,
        duration_ms: 150
      )

      @error_log = model.create!(
        http_method: 'POST',
        url: 'https://api.example.com/orders',
        status_code: 500,
        duration_ms: 2500
      )

      @slow_log = model.create!(
        http_method: 'PUT',
        url: 'https://api.example.com/slow',
        status_code: 200,
        duration_ms: 1500
      )
    end

    it 'filters by status code' do
      logs = model.with_status(200)

      _(logs.count).must_equal 2
      _(logs).must_include @success_log
      _(logs).must_include @slow_log
    end

    it 'filters by HTTP method' do
      logs = model.with_method('GET')

      _(logs.count).must_equal 1
      _(logs.first).must_equal @success_log
    end

    it 'finds successful requests' do
      logs = model.successful

      _(logs.count).must_equal 2
      _(logs).must_include @success_log
      _(logs).must_include @slow_log
    end

    it 'finds failed requests' do
      logs = model.failed

      _(logs.count).must_equal 1
      _(logs.first).must_equal @error_log
    end

    it 'finds slow requests' do
      logs = model.slow(1000)

      _(logs.count).must_equal 2
      _(logs).must_include @error_log
      _(logs).must_include @slow_log
    end
  end

  describe '.log_request' do
    it 'creates a log entry with all data' do
      OutboundHttpLogger.with_configuration(enabled: true) do
        request_data = {
          headers: { 'Content-Type' => 'application/json', 'Authorization' => 'Bearer token' },
          body: '{"name": "test"}',
          metadata: { 'source' => 'test' }
        }

        response_data = {
          status_code: 201,
          headers: { 'Content-Type' => 'application/json' },
          body: '{"id": 1, "name": "test"}'
        }

        log = model.log_request('POST', 'https://api.example.com/users', request_data, response_data, 0.25)

        _(log).wont_be_nil
        _(log.http_method).must_equal 'POST'
        _(log.url).must_equal 'https://api.example.com/users'
        _(log.status_code).must_equal 201
        _(log.duration_seconds).must_equal 0.25
        _(log.duration_ms).must_equal 250.0
        _(log.request_headers['Authorization']).must_equal '[FILTERED]'
        _(log.request_headers['Content-Type']).must_equal 'application/json'
        _(log.response_body).must_equal '{"id":1,"name":"test"}'
      end
    end

    it 'returns nil when logging is disabled' do
      OutboundHttpLogger.disable!

      log = model.log_request('GET', 'https://api.example.com/users', {}, {}, 0.1)

      _(log).must_be_nil
    end

    it 'returns nil for excluded URLs' do
      OutboundHttpLogger.with_configuration(enabled: true) do
        log = model.log_request('GET', 'https://api.example.com/health', {}, {}, 0.1)

        _(log).must_be_nil
      end
    end

    it 'returns nil for excluded content types' do
      OutboundHttpLogger.with_configuration(enabled: true) do
        response_data = {
          status_code: 200,
          headers: { 'Content-Type' => 'text/html' },
          body: '<html></html>'
        }

        log = model.log_request('GET', 'https://api.example.com/page', {}, response_data, 0.1)

        _(log).must_be_nil
      end
    end

    it 'handles errors gracefully' do
      # Mock the create! method to raise an error
      model.stubs(:create!).raises(StandardError, 'Database error')

      # Should not raise an error, just return nil
      log = model.log_request('GET', 'https://api.example.com/users', {}, {}, 0.1)

      _(log).must_be_nil
    end
  end

  describe 'instance methods' do
    let(:log) do
      model.create!(
        http_method: 'POST',
        url: 'https://api.example.com/users',
        status_code: 201,
        duration_ms: 150.5,
        duration_seconds: 0.1505,
        request_headers: { 'Content-Type' => 'application/json' },
        request_body: '{"name": "John"}',
        response_headers: { 'Content-Type' => 'application/json' },
        response_body: '{"id": 1, "name": "John"}'
      )
    end

    it 'formats duration correctly' do
      _(log.formatted_duration).must_equal '150.5ms'

      slow_log = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/slow',
        status_code: 200,
        duration_ms: 2500,
        duration_seconds: 2.5
      )

      _(slow_log.formatted_duration).must_equal '2.5s'
    end

    it 'determines success status' do
      _(log.success?).must_equal true
      _(log.failure?).must_equal false

      error_log = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/error',
        status_code: 500
      )

      _(error_log.success?).must_equal false
      _(error_log.failure?).must_equal true
    end

    it 'determines if request is slow' do
      _(log.slow?).must_equal false
      _(log.slow?(100)).must_equal true
    end

    it 'provides status text' do
      _(log.status_text).must_equal 'Created'

      not_found_log = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/notfound',
        status_code: 404
      )

      _(not_found_log.status_text).must_equal 'Not Found'
    end

    it 'formats request and response' do
      request_format = log.formatted_request

      _(request_format).must_include 'POST https://api.example.com/users'
      _(request_format).must_include 'Content-Type: application/json'
      _(request_format).must_include '{"name": "John"}'

      response_format = log.formatted_response

      _(response_format).must_include 'HTTP 201 Created'
      _(response_format).must_include 'Content-Type: application/json'
      _(response_format).must_include '{"id": 1, "name": "John"}'
    end
  end

  describe 'search functionality' do
    before do
      @user_log = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/users',
        status_code: 200,
        request_body: '{"filter": "active"}',
        response_body: '{"users": [{"name": "John"}]}'
      )

      @order_log = model.create!(
        http_method: 'POST',
        url: 'https://api.example.com/orders',
        status_code: 201,
        request_body: '{"product": "widget"}',
        response_body: '{"order_id": 123}'
      )
    end

    it 'searches by general query' do
      results = model.search(q: 'users')

      _(results.count).must_equal 1
      _(results.first).must_equal @user_log

      results = model.search(q: 'widget')

      _(results.count).must_equal 1
      _(results.first).must_equal @order_log
    end

    it 'filters by status' do
      results = model.search(status: 200)

      _(results.count).must_equal 1
      _(results.first).must_equal @user_log
    end

    it 'filters by method' do
      results = model.search(method: 'POST')

      _(results.count).must_equal 1
      _(results.first).must_equal @order_log
    end
  end

  describe 'loggable associations' do
    it 'can associate logs with metadata' do
      OutboundHttpLogger.with_configuration(enabled: true) do
        request_data = {
          headers: { 'Content-Type' => 'application/json' },
          body: '{"test": true}',
          metadata: { action: 'test_action', user_id: 123 }
        }

        response_data = {
          status_code: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: '{"success": true}'
        }

        log = model.log_request('POST', 'https://api.example.com/users', request_data, response_data, 0.1)

        _(log).wont_be_nil
        _(log.metadata['action']).must_equal 'test_action'
        _(log.metadata['user_id']).must_equal 123
      end
    end

    it 'can create logs with loggable_type and loggable_id' do
      log = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/users1',
        status_code: 200,
        loggable_type: 'User',
        loggable_id: 123
      )

      _(log.loggable_type).must_equal 'User'
      _(log.loggable_id).must_equal 123
    end

    it 'can search logs by loggable type and id' do
      log = model.create!(
        http_method: 'POST',
        url: 'https://api.example.com/orders',
        status_code: 201,
        loggable_type: 'Order',
        loggable_id: 456
      )

      results = model.search(loggable_type: 'Order', loggable_id: 456)

      _(results.count).must_equal 1
      _(results.first).must_equal log
    end

    it 'handles nil loggable gracefully' do
      OutboundHttpLogger.with_configuration(enabled: true) do
        request_data = {
          headers: { 'Content-Type' => 'application/json' },
          body: '{"test": true}',
          loggable: nil,
          metadata: { action: 'no_loggable' }
        }

        response_data = {
          status_code: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: '{"success": true}'
        }

        log = model.log_request('GET', 'https://api.example.com/users', request_data, response_data, 0.1)

        _(log).wont_be_nil
        _(log.loggable).must_be_nil
        _(log.metadata['action']).must_equal 'no_loggable'
      end
    end

    it 'can query logs by loggable_type' do
      log1 = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/users',
        status_code: 200,
        loggable_type: 'User',
        loggable_id: 1
      )

      log2 = model.create!(
        http_method: 'GET',
        url: 'https://api.example.com/orders',
        status_code: 200,
        loggable_type: 'Order',
        loggable_id: 1
      )

      user_logs = model.where(loggable_type: 'User')

      _(user_logs.count).must_equal 1
      _(user_logs.first).must_equal log1

      order_logs = model.where(loggable_type: 'Order')

      _(order_logs.count).must_equal 1
      _(order_logs.first).must_equal log2
    end
  end
end

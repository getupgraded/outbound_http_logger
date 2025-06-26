# frozen_string_literal: true

require 'test_helper'

describe OutboundHTTPLogger do
  it 'has a version number' do
    _(OutboundHTTPLogger::VERSION).wont_be_nil
  end

  describe 'configuration' do
    it 'starts disabled by default' do
      _(OutboundHTTPLogger.enabled?).must_equal false
    end

    it 'can be enabled and disabled' do
      OutboundHTTPLogger.enable!

      _(OutboundHTTPLogger.enabled?).must_equal true

      OutboundHTTPLogger.disable!

      _(OutboundHTTPLogger.enabled?).must_equal false
    end

    it 'can be configured with a block' do
      # Use thread-safe configuration to avoid modifying global config
      OutboundHTTPLogger.with_configuration(enabled: true, debug_logging: true) do
        _(OutboundHTTPLogger.enabled?).must_equal true
        _(OutboundHTTPLogger.configuration.debug_logging).must_equal true
      end
    end
  end

  describe 'URL exclusion' do
    it 'excludes Sentry URLs by default' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        sentry_url = 'https://o1234567.ingest.us.sentry.io/api/10001/envelope/'

        _(OutboundHTTPLogger.configuration.should_log_url?(sentry_url)).must_equal false
      end
    end

    it 'excludes health check URLs by default' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        health_url = 'https://api.example.com/health'

        _(OutboundHTTPLogger.configuration.should_log_url?(health_url)).must_equal false
      end
    end

    it 'allows normal API URLs' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        api_url = 'https://api.example.com/users'

        _(OutboundHTTPLogger.configuration.should_log_url?(api_url)).must_equal true
      end
    end

    it 'can add custom exclusion patterns' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        OutboundHTTPLogger.configuration.excluded_urls << %r{/custom-exclude}

        excluded_url = 'https://api.example.com/custom-exclude/test'

        _(OutboundHTTPLogger.configuration.should_log_url?(excluded_url)).must_equal false
      end
    end
  end

  describe 'content type filtering' do
    it 'excludes HTML content by default' do
      _(OutboundHTTPLogger.configuration.should_log_content_type?('text/html')).must_equal false
    end

    it 'excludes image content by default' do
      _(OutboundHTTPLogger.configuration.should_log_content_type?('image/png')).must_equal false
    end

    it 'allows JSON content' do
      _(OutboundHTTPLogger.configuration.should_log_content_type?('application/json')).must_equal true
    end

    it 'allows unknown content types' do
      _(OutboundHTTPLogger.configuration.should_log_content_type?(nil)).must_equal true
      _(OutboundHTTPLogger.configuration.should_log_content_type?('')).must_equal true
    end
  end

  describe 'sensitive data filtering' do
    it 'filters authorization headers' do
      headers  = { 'Authorization' => 'Bearer secret-token', 'Content-Type' => 'application/json' }
      filtered = OutboundHTTPLogger.configuration.filter_headers(headers)

      _(filtered['Authorization']).must_equal '[FILTERED]'
      _(filtered['Content-Type']).must_equal 'application/json'
    end

    it 'filters sensitive JSON body keys' do
      body     = '{"username": "john", "password": "secret123", "email": "john@example.com"}'
      filtered = OutboundHTTPLogger.configuration.filter_body(body)

      parsed = JSON.parse(filtered)

      _(parsed['password']).must_equal '[FILTERED]'
      _(parsed['username']).must_equal 'john'
      _(parsed['email']).must_equal 'john@example.com'
    end

    it 'handles non-JSON body content' do
      body     = 'plain text content'
      filtered = OutboundHTTPLogger.configuration.filter_body(body)

      _(filtered).must_equal body
    end

    it 'truncates large bodies' do
      large_body = 'x' * 20_000
      filtered   = OutboundHTTPLogger.configuration.filter_body(large_body)

      _(filtered).must_equal large_body # Should return as-is when too large
    end
  end

  describe 'thread-local data management' do
    it 'can set and clear metadata' do
      metadata = { user_id: 123, action: 'sync' }
      OutboundHTTPLogger.set_metadata(metadata)

      _(Thread.current[:outbound_http_logger_metadata]).must_equal metadata

      OutboundHTTPLogger.clear_thread_data

      _(Thread.current[:outbound_http_logger_metadata]).must_be_nil
    end

    it 'can set and clear loggable' do
      loggable = Object.new
      OutboundHTTPLogger.set_loggable(loggable)

      _(Thread.current[:outbound_http_logger_loggable]).must_equal loggable

      OutboundHTTPLogger.clear_thread_data

      _(Thread.current[:outbound_http_logger_loggable]).must_be_nil
    end

    it 'with_logging method preserves and restores thread data' do
      # Set initial values
      initial_loggable = Object.new
      initial_metadata = { initial: true }
      OutboundHTTPLogger.set_loggable(initial_loggable)
      OutboundHTTPLogger.set_metadata(initial_metadata)

      # Use with_logging to temporarily change values
      new_loggable = Object.new
      new_metadata = { temporary: true }

      OutboundHTTPLogger.with_logging(loggable: new_loggable, metadata: new_metadata) do
        _(Thread.current[:outbound_http_logger_loggable]).must_equal new_loggable
        _(Thread.current[:outbound_http_logger_metadata]).must_equal new_metadata
      end

      # Values should be restored
      _(Thread.current[:outbound_http_logger_loggable]).must_equal initial_loggable
      _(Thread.current[:outbound_http_logger_metadata]).must_equal initial_metadata

      # Clean up the initial values we set
      OutboundHTTPLogger.clear_thread_data
    end

    it 'with_logging method works with nil initial values' do
      # Clear any existing values
      OutboundHTTPLogger.clear_thread_data

      new_loggable = Object.new
      new_metadata = { test: true }

      OutboundHTTPLogger.with_logging(loggable: new_loggable, metadata: new_metadata) do
        _(Thread.current[:outbound_http_logger_loggable]).must_equal new_loggable
        _(Thread.current[:outbound_http_logger_metadata]).must_equal new_metadata
      end

      # Values should be restored to nil
      _(Thread.current[:outbound_http_logger_loggable]).must_be_nil
      _(Thread.current[:outbound_http_logger_metadata]).must_be_nil
    end
  end
end

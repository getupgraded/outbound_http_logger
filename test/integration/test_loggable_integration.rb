# frozen_string_literal: true

require 'test_helper'

describe 'Loggable Integration Tests' do
  include TestHelpers

  let(:log_model) { OutboundHTTPLogger::Models::OutboundRequestLog }

  describe 'thread-local data integration' do
    it 'stores and retrieves loggable and metadata' do
      with_outbound_http_logging_enabled do
        # Test setting loggable
        mock_user = Object.new
        OutboundHTTPLogger.set_loggable(mock_user)

        _(Thread.current[:outbound_http_logger_loggable]).must_equal mock_user

        # Test setting metadata
        metadata = { action: 'test', user_id: 123 }
        OutboundHTTPLogger.set_metadata(metadata)

        _(Thread.current[:outbound_http_logger_metadata]).must_equal metadata

        # Test clearing data
        OutboundHTTPLogger.clear_thread_data

        _(Thread.current[:outbound_http_logger_loggable]).must_be_nil
        _(Thread.current[:outbound_http_logger_metadata]).must_be_nil
      end
    end

    it 'with_logging method works correctly' do
      with_outbound_http_logging_enabled do
        # Set initial values
        initial_user     = Object.new
        initial_metadata = { initial: true }
        OutboundHTTPLogger.set_loggable(initial_user)
        OutboundHTTPLogger.set_metadata(initial_metadata)

        # Use with_logging to temporarily change values
        temp_user     = Object.new
        temp_metadata = { temporary: true }

        OutboundHTTPLogger.with_logging(loggable: temp_user, metadata: temp_metadata) do
          _(Thread.current[:outbound_http_logger_loggable]).must_equal temp_user
          _(Thread.current[:outbound_http_logger_metadata]).must_equal temp_metadata
        end

        # Values should be restored
        _(Thread.current[:outbound_http_logger_loggable]).must_equal initial_user
        _(Thread.current[:outbound_http_logger_metadata]).must_equal initial_metadata

        # Clean up the initial values we set
        OutboundHTTPLogger.clear_thread_data
      end
    end
  end

  describe 'log_request with thread-local data' do
    it 'includes thread-local metadata in logs' do
      OutboundHTTPLogger.with_configuration(enabled: true, logger: Logger.new(StringIO.new)) do
        # Set thread-local metadata (skip loggable for now due to ActiveRecord complexity)
        metadata = { action: 'api_call', source: 'test', user_id: 123 }
        OutboundHTTPLogger.set_metadata(metadata)

        # Manually call log_request to test the functionality
        request_data = {
          headers: { 'Content-Type' => 'application/json' },
          body: '{"test": true}',
          loggable: nil, # Skip complex loggable for this test
          metadata: Thread.current[:outbound_http_logger_metadata]
        }

        response_data = {
          status_code: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: '{"success": true}'
        }

        log = log_model.log_request('POST', 'https://api.example.com/users', request_data, response_data, 0.1)

        _(log).wont_be_nil
        _(log.loggable).must_be_nil
        _(log.metadata['action']).must_equal 'api_call'
        _(log.metadata['source']).must_equal 'test'
        _(log.metadata['user_id']).must_equal 123

        # Clean up thread-local data
        OutboundHTTPLogger.clear_thread_data
      end
    end

    it 'can create logs with loggable_type and loggable_id directly' do
      with_outbound_http_logging_enabled do
        # Test creating a log with loggable_type and loggable_id instead of a real object
        log = log_model.create!(
          http_method: 'GET',
          url: 'https://api.example.com/users',
          status_code: 200,
          loggable_type: 'User',
          loggable_id: 123,
          metadata: { action: 'fetch_user' }
        )

        _(log).wont_be_nil
        _(log.loggable_type).must_equal 'User'
        _(log.loggable_id).must_equal 123
        _(log.metadata['action']).must_equal 'fetch_user'
      end
    end
  end
end

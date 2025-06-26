# frozen_string_literal: true

require 'test_helper'

describe OutboundHTTPLogger::Concerns::OutboundLogging do
  before do
    # Clear thread-local data before each test
    Thread.current[:outbound_http_logger_loggable] = nil
    Thread.current[:outbound_http_logger_metadata] = nil
  end

  after do
    # Clean up thread-local data after each test
    OutboundHTTPLogger.clear_thread_data
  end

  # Create a class that includes the concern
  let(:controller_class) do
    Class.new do
      include OutboundHTTPLogger::Concerns::OutboundLogging
    end
  end

  let(:controller_instance) { controller_class.new }
  let(:mock_object) { Object.new }

  describe 'set_outbound_log_loggable' do
    it 'sets the loggable in thread-local storage' do
      controller_instance.set_outbound_log_loggable(mock_object)

      _(Thread.current[:outbound_http_logger_loggable]).must_equal mock_object
    end
  end

  describe 'add_outbound_log_metadata' do
    it 'sets metadata in thread-local storage' do
      metadata = { user_id: 123, action: 'test' }
      controller_instance.add_outbound_log_metadata(metadata)

      _(Thread.current[:outbound_http_logger_metadata]).must_equal metadata
    end

    it 'merges with existing metadata' do
      # Set initial metadata
      initial_metadata = { user_id: 123 }
      controller_instance.add_outbound_log_metadata(initial_metadata)

      # Add more metadata
      additional_metadata = { action: 'test', timestamp: '2023-01-01' }
      controller_instance.add_outbound_log_metadata(additional_metadata)

      expected_metadata = { user_id: 123, action: 'test', timestamp: '2023-01-01' }

      _(Thread.current[:outbound_http_logger_metadata]).must_equal expected_metadata
    end
  end

  describe 'clear_outbound_log_data' do
    it 'clears thread-local data' do
      # Set some data
      controller_instance.set_outbound_log_loggable(mock_object)
      controller_instance.add_outbound_log_metadata({ test: true })

      # Clear it
      controller_instance.clear_outbound_log_data

      _(Thread.current[:outbound_http_logger_loggable]).must_be_nil
      _(Thread.current[:outbound_http_logger_metadata]).must_be_nil
    end
  end

  describe 'with_outbound_logging' do
    it 'temporarily sets loggable and metadata' do
      # Set initial values
      initial_loggable = Object.new
      initial_metadata = { initial: true }
      controller_instance.set_outbound_log_loggable(initial_loggable)
      controller_instance.add_outbound_log_metadata(initial_metadata)

      # Use with_outbound_logging
      temp_loggable = Object.new
      temp_metadata = { temporary: true }

      controller_instance.with_outbound_logging(loggable: temp_loggable, metadata: temp_metadata) do
        _(Thread.current[:outbound_http_logger_loggable]).must_equal temp_loggable
        _(Thread.current[:outbound_http_logger_metadata]).must_equal temp_metadata
      end

      # Values should be restored
      _(Thread.current[:outbound_http_logger_loggable]).must_equal initial_loggable
      _(Thread.current[:outbound_http_logger_metadata]).must_equal initial_metadata
    end

    it 'works with only loggable parameter' do
      temp_loggable = Object.new

      controller_instance.with_outbound_logging(loggable: temp_loggable) do
        _(Thread.current[:outbound_http_logger_loggable]).must_equal temp_loggable
      end
    end

    it 'works with only metadata parameter' do
      temp_metadata = { test: true }

      controller_instance.with_outbound_logging(metadata: temp_metadata) do
        _(Thread.current[:outbound_http_logger_metadata]).must_equal temp_metadata
      end
    end

    it 'restores nil values correctly' do
      # Clear any existing values
      controller_instance.clear_outbound_log_data

      temp_loggable = Object.new
      temp_metadata = { test: true }

      controller_instance.with_outbound_logging(loggable: temp_loggable, metadata: temp_metadata) do
        _(Thread.current[:outbound_http_logger_loggable]).must_equal temp_loggable
        _(Thread.current[:outbound_http_logger_metadata]).must_equal temp_metadata
      end

      # Should be restored to nil
      _(Thread.current[:outbound_http_logger_loggable]).must_be_nil
      _(Thread.current[:outbound_http_logger_metadata]).must_be_nil
    end
  end
end

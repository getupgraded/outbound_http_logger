# frozen_string_literal: true

require 'test_helper'
require 'ostruct'

# rubocop:disable Style/OpenStructUse

class TestReadmeExamples < Minitest::Test
  def setup
    # Reset configuration to default state
    config = OutboundHTTPLogger.global_configuration
    config.enabled = false
    config.excluded_urls = [
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
      api_key
      access_token
      refresh_token
      private_key
      credit_card
      ssn
    ]
    config.max_body_size = OutboundHTTPLogger::Configuration::DEFAULT_MAX_BODY_SIZE
    config.debug_logging = false
    config.logger = nil
    config.secondary_database_url = nil
    config.secondary_database_adapter = :sqlite
    config.max_recursion_depth = OutboundHTTPLogger::Configuration::DEFAULT_MAX_RECURSION_DEPTH
    config.strict_recursion_detection = false

    OutboundHTTPLogger.clear_all_thread_data

    # Enable logging for tests
    OutboundHTTPLogger.enable!
  end

  def teardown
    OutboundHTTPLogger.clear_all_thread_data
    OutboundHTTPLogger.disable!
  end

  def test_basic_configuration_example
    # Test the basic configuration example from README
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.excluded_urls << /private-api/
      config.sensitive_headers << 'x-custom-token'
      config.max_body_size = 5000
    end

    assert_predicate OutboundHTTPLogger, :enabled?
    assert_includes OutboundHTTPLogger.configuration.excluded_urls.map(&:source), 'private-api'
    assert_includes OutboundHTTPLogger.configuration.sensitive_headers, 'x-custom-token'
    assert_equal 5000, OutboundHTTPLogger.configuration.max_body_size
  end

  def test_thread_local_association_example
    # Create a mock user object
    user = OpenStruct.new(id: 123, name: 'Test User')

    # Test the thread-local association example from README
    OutboundHTTPLogger.set_loggable(user)
    OutboundHTTPLogger.set_metadata(action: 'bulk_sync', batch_id: 123)

    # Verify the thread-local data is set
    assert_equal user, OutboundHTTPLogger::ThreadContext.loggable
    assert_equal({ action: 'bulk_sync', batch_id: 123 }, OutboundHTTPLogger::ThreadContext.metadata)

    # Clear thread-local data
    OutboundHTTPLogger.clear_thread_data

    # Verify data is cleared
    assert_nil OutboundHTTPLogger::ThreadContext.loggable
    assert_nil OutboundHTTPLogger::ThreadContext.metadata
  end

  def test_scoped_association_example
    # Create mock objects
    order = OpenStruct.new(id: 456, total: 100.0)

    # Test the scoped association example from README
    result = OutboundHTTPLogger.with_logging(loggable: order, metadata: { action: 'fulfillment' }) do
      # Verify context is set within the block
      assert_equal order, OutboundHTTPLogger::ThreadContext.loggable
      assert_equal({ action: 'fulfillment' }, OutboundHTTPLogger::ThreadContext.metadata)
      'block_result'
    end

    # Verify the block result is returned
    assert_equal 'block_result', result

    # Verify context is restored after the block
    assert_nil OutboundHTTPLogger::ThreadContext.loggable
    assert_nil OutboundHTTPLogger::ThreadContext.metadata
  end

  def test_outbound_logging_concern_example
    # Create a mock controller class that includes the concern
    controller_class = Class.new do
      include OutboundHTTPLogger::Concerns::OutboundLogging

      def initialize
        @user = OpenStruct.new(id: 789, name: 'Controller User')
      end

      def sync_user_action
        # Test the concern methods from README example
        set_outbound_log_loggable(@user)
        add_outbound_log_metadata(action: 'user_sync', source: 'manual')

        # Return the current context for verification
        {
          loggable: OutboundHTTPLogger::ThreadContext.loggable,
          metadata: OutboundHTTPLogger::ThreadContext.metadata
        }
      end
    end

    controller = controller_class.new
    result = controller.sync_user_action

    # Verify the concern methods work correctly
    assert_equal 789, result[:loggable].id
    assert_equal 'Controller User', result[:loggable].name
    assert_equal 'user_sync', result[:metadata][:action]
    assert_equal 'manual', result[:metadata][:source]
  end

  def test_with_configuration_example
    # Test the with_configuration example from README
    original_enabled = OutboundHTTPLogger.configuration.enabled?
    original_debug = OutboundHTTPLogger.configuration.debug_logging

    result = OutboundHTTPLogger.with_configuration(enabled: true, debug_logging: true) do
      # Verify temporary configuration is active
      assert_predicate OutboundHTTPLogger.configuration, :enabled?
      assert OutboundHTTPLogger.configuration.debug_logging
      'temp_config_result'
    end

    # Verify the block result is returned
    assert_equal 'temp_config_result', result

    # Verify original configuration is restored
    assert_equal original_enabled, OutboundHTTPLogger.configuration.enabled?
    assert_equal original_debug, OutboundHTTPLogger.configuration.debug_logging
  end

  def test_secondary_database_configuration_example
    # Test secondary database configuration from README
    OutboundHTTPLogger.enable_secondary_logging!('sqlite3:///tmp/test_secondary.sqlite3', adapter: :sqlite)

    assert_predicate OutboundHTTPLogger, :secondary_logging_enabled?
    assert_equal 'sqlite3:///tmp/test_secondary.sqlite3', OutboundHTTPLogger.configuration.secondary_database_url
    assert_equal :sqlite, OutboundHTTPLogger.configuration.secondary_database_adapter

    # Clean up
    OutboundHTTPLogger.disable_secondary_logging!

    refute_predicate OutboundHTTPLogger, :secondary_logging_enabled?
  end

  def test_url_exclusion_example
    # Test URL exclusion configuration from README
    OutboundHTTPLogger.configure do |config|
      config.excluded_urls = [
        /health/,
        /metrics/,
        %r{https://api\.internal\.com}
      ]
    end

    config = OutboundHTTPLogger.configuration

    # Test URL exclusion logic
    refute config.should_log_url?('https://api.example.com/health')
    refute config.should_log_url?('https://api.example.com/metrics')
    refute config.should_log_url?('https://api.internal.com/users')
    assert config.should_log_url?('https://api.external.com/users')
  end

  def test_content_type_exclusion_example
    # Test content type exclusion from README
    OutboundHTTPLogger.configure do |config|
      config.excluded_content_types = [
        'text/html',
        'image/',
        'application/javascript'
      ]
    end

    config = OutboundHTTPLogger.configuration

    # Test content type exclusion logic
    refute config.should_log_content_type?('text/html')
    refute config.should_log_content_type?('image/png')
    refute config.should_log_content_type?('image/jpeg')
    refute config.should_log_content_type?('application/javascript')
    assert config.should_log_content_type?('application/json')
    assert config.should_log_content_type?('text/plain')
  end

  def test_test_utilities_api_examples
    # Test the Test utilities API examples from README
    require 'outbound_http_logger/test'

    # Configure and enable test logging
    OutboundHTTPLogger::Test.configure(
      database_url: 'sqlite3:///tmp/test_readme_examples.sqlite3',
      adapter: :sqlite
    )
    OutboundHTTPLogger::Test.enable!

    # Clear any existing logs
    OutboundHTTPLogger::Test.clear_logs!

    # Test basic counting
    initial_count = OutboundHTTPLogger::Test.logs_count

    assert_equal 0, initial_count

    # Test getting all logs (should be empty initially)
    all_logs = OutboundHTTPLogger::Test.all_logs

    assert_empty all_logs

    # Test reset functionality
    OutboundHTTPLogger::Test.reset!

    refute_predicate OutboundHTTPLogger::Test, :enabled?

    # Re-enable for cleanup
    OutboundHTTPLogger::Test.enable!
    OutboundHTTPLogger::Test.clear_logs!
    OutboundHTTPLogger::Test.disable!
  end
end

# rubocop:enable Style/OpenStructUse

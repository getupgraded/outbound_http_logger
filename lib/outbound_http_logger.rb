# frozen_string_literal: true

require 'active_record'
require 'active_support'
require_relative 'outbound_http_logger/version'
require_relative 'outbound_http_logger/configuration'
require_relative 'outbound_http_logger/error_handling'
require_relative 'outbound_http_logger/thread_context'
require_relative 'outbound_http_logger/database_adapters/postgresql_adapter'
require_relative 'outbound_http_logger/database_adapters/sqlite_adapter'
require_relative 'outbound_http_logger/models/outbound_request_log'
require_relative 'outbound_http_logger/concerns/outbound_logging'
require_relative 'outbound_http_logger/patches/common_patch_behavior'
require_relative 'outbound_http_logger/patches/net_http_patch'
require_relative 'outbound_http_logger/patches/faraday_patch'
require_relative 'outbound_http_logger/patches/httparty_patch'
require_relative 'outbound_http_logger/logger'
require_relative 'outbound_http_logger/railtie' if defined?(Rails)

module OutboundHTTPLogger
  class Error < StandardError; end
  class InfiniteRecursionError < Error; end

  # Simple global configuration (not frequently changed, no atomic operations needed)
  @global_configuration = nil
  @logger = nil

  class << self
    # Configuration instance (checks for thread-local override first)
    def configuration
      Thread.current[:outbound_http_logger_config_override] || global_configuration
    end

    # Global configuration instance (simple lazy initialization)
    def global_configuration
      @global_configuration ||= Configuration.new
    end

    # Configure the gem with a block
    def configure
      yield(configuration) if block_given?
      setup_patches if configuration.enabled?
    end

    # Thread-safe temporary configuration override for testing
    def with_configuration(**overrides)
      return yield if overrides.empty?

      # Create a copy of the current configuration (which may already be an override)
      current_config = configuration
      backup = current_config.backup
      temp_config = Configuration.new
      temp_config.restore(backup)

      # Apply overrides
      overrides.each { |key, value| temp_config.public_send("#{key}=", value) }

      # Set thread-local override
      previous_override = Thread.current[:outbound_http_logger_config_override]
      Thread.current[:outbound_http_logger_config_override] = temp_config

      # Apply patches if logging was enabled in the override
      setup_patches if temp_config.enabled?

      yield
    ensure
      Thread.current[:outbound_http_logger_config_override] = previous_override
    end

    # Enable logging (can be called without a block)
    def enable!
      configuration.enabled = true
      apply_patches_if_needed
    end

    # Disable logging
    def disable!
      configuration.enabled = false
    end

    # Check if logging is enabled
    delegate :enabled?, to: :configuration

    # Get the logger instance
    # Don't cache the logger since configuration can change (especially in tests)
    def logger
      Logger.new(configuration)
    end

    # Set metadata for the current thread's outbound requests
    def set_metadata(metadata)
      ThreadContext.metadata = metadata
    end

    # Set loggable for the current thread's outbound requests
    def set_loggable(loggable)
      ThreadContext.loggable = loggable
    end

    # Clear thread-local data
    # This method clears the core thread-local data used by OutboundHTTPLogger
    # For comprehensive cleanup (including internal state), use clear_all_thread_data
    def clear_thread_data
      ThreadContext.clear_user_data
    end

    # Clear ALL thread-local data including internal state variables
    # Use this for comprehensive cleanup in test environments
    def clear_all_thread_data
      ThreadContext.clear_all
    end

    # Secondary database logging methods

    # Enable secondary database logging
    def enable_secondary_logging!(database_url = nil, adapter: :sqlite)
      database_url ||= default_secondary_database_url(adapter)
      configuration.configure_secondary_database(database_url, adapter: adapter)
    end

    # Disable secondary database logging
    def disable_secondary_logging!
      configuration.clear_secondary_database
    end

    # Check if secondary database logging is configured
    def secondary_logging_enabled?
      configuration.secondary_database_configured?
    end

    # Execute a block with specific loggable and metadata for outbound requests
    def with_logging(loggable: nil, metadata: {}, &)
      ThreadContext.with_context(loggable: loggable, metadata: metadata, &)
    end

    # Execute a block with complete thread isolation (configuration + data)
    # This is the recommended method for testing and ensures no leakage
    def with_isolated_context(loggable: nil, metadata: {}, **config_overrides)
      # Backup complete thread context
      context_backup = ThreadContext.backup_current

      begin
        # Apply configuration overrides if provided
        if config_overrides.any?
          current_config = configuration
          backup = current_config.backup
          temp_config = Configuration.new
          temp_config.restore(backup)

          # Apply overrides
          config_overrides.each { |key, value| temp_config.public_send("#{key}=", value) }

          # Set thread-local configuration override
          previous_override = Thread.current[:outbound_http_logger_config_override]
          Thread.current[:outbound_http_logger_config_override] = temp_config

          begin
            # Apply patches if logging was enabled in the override
            setup_patches if temp_config.enabled?

            # Set thread-local data if provided
            ThreadContext.loggable = loggable if loggable
            ThreadContext.metadata = metadata if metadata.any?

            yield
          ensure
            Thread.current[:outbound_http_logger_config_override] = previous_override
          end
        else
          # No config overrides, just set thread-local data
          ThreadContext.loggable = loggable if loggable
          ThreadContext.metadata = metadata if metadata.any?
          yield
        end
      ensure
        # Restore complete thread context
        ThreadContext.restore(context_backup)
      end
    end

    # Reset configuration to defaults (useful for testing)
    # WARNING: This will lose all customizations from initializers
    def reset_configuration!
      # Simple reset of configuration and logger
      @global_configuration = nil
      @logger = nil
      # Also clear any thread-local overrides
      Thread.current[:outbound_http_logger_config_override] = nil
    end

    # Create a new configuration instance with defaults
    def create_fresh_configuration
      Configuration.new
    end

    # Clear thread-local configuration override
    def clear_configuration_override
      Thread.current[:outbound_http_logger_config_override] = nil
    end

    # Reset patch application state (for testing)
    def reset_patches!
      Patches::NetHTTPPatch.reset!
      Patches::FaradayPatch.reset!
      Patches::HTTPartyPatch.reset!
    end

    # Complete reset for testing (patches, configuration, thread data)
    def reset_for_testing!
      reset_patches!
      Models::OutboundRequestLog.reset_adapter_cache!
      reset_configuration!
      clear_thread_data
    end

    private

      def default_secondary_database_url(adapter)
        case adapter.to_sym
        when :sqlite
          'sqlite3:///log/outbound_requests.sqlite3'
        when :postgresql
          ENV['OUTBOUND_LOGGING_DATABASE_URL'] || 'postgresql://localhost/outbound_logs'
        else
          raise ArgumentError, "Unsupported adapter: #{adapter}"
        end
      end

      # Set up HTTP library patches when enabled
      def setup_patches
        return unless configuration.enabled?

        Patches::NetHTTPPatch.apply! if defined?(Net::HTTP)
        Patches::FaradayPatch.apply! if defined?(Faraday)
        Patches::HTTPartyPatch.apply! if defined?(HTTParty)
      end

      # Apply patches immediately when libraries are available
      def apply_patches_if_needed
        setup_patches if configuration.enabled?
      end
  end
end

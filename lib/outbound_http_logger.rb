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
    # Get the current configuration instance (checks for thread-local override first)
    # @return [Configuration] The current configuration (thread-local override or global)
    def configuration
      Thread.current[:outbound_http_logger_config_override] || global_configuration
    end

    # Get the global configuration instance (simple lazy initialization)
    # @return [Configuration] The global configuration object
    def global_configuration
      @global_configuration ||= Configuration.new
    end

    # Configure the gem with a block
    # @yield [Configuration] Yields the current configuration for modification
    # @return [void]
    # @example
    #   OutboundHTTPLogger.configure do |config|
    #     config.enabled = true
    #     config.excluded_urls << /private-api/
    #   end
    def configure
      yield(configuration) if block_given?
      setup_patches if configuration.enabled?
    end

    # Thread-safe temporary configuration override for testing
    # @param overrides [Hash] Configuration attributes to override
    # @yield Block to execute with the temporary configuration
    # @return [Object] The result of the yielded block
    # @example
    #   OutboundHTTPLogger.with_configuration(enabled: true, debug_logging: true) do
    #     # Code here runs with temporary configuration
    #     HTTParty.get('https://api.example.com')
    #   end
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

    # Enable logging and apply HTTP library patches
    # @return [void]
    def enable!
      configuration.enabled = true
      apply_patches_if_needed
    end

    # Disable logging
    # @return [void]
    def disable!
      configuration.enabled = false
    end

    # Check if logging is enabled
    # @return [Boolean] true if logging is enabled
    delegate :enabled?, to: :configuration

    # Get the logger instance
    # Don't cache the logger since configuration can change (especially in tests)
    # @return [Logger] The logger instance for recording HTTP requests
    def logger
      Logger.new(configuration)
    end

    # Set metadata for the current thread's outbound requests
    # @param metadata [Hash] Metadata to associate with outbound requests
    # @return [void]
    # @example
    #   OutboundHTTPLogger.set_metadata(user_id: 123, action: 'sync')
    def set_metadata(metadata)
      ThreadContext.metadata = metadata
    end

    # Set loggable for the current thread's outbound requests
    # @param loggable [Object] ActiveRecord model or other object to associate with requests
    # @return [void]
    # @example
    #   OutboundHTTPLogger.set_loggable(current_user)
    def set_loggable(loggable)
      ThreadContext.loggable = loggable
    end

    # Clear thread-local data
    # This method clears the core thread-local data used by OutboundHTTPLogger
    # For comprehensive cleanup (including internal state), use clear_all_thread_data
    # @return [void]
    def clear_thread_data
      ThreadContext.clear_user_data
    end

    # Clear ALL thread-local data including internal state variables
    # Use this for comprehensive cleanup in test environments
    # @return [void]
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

    # Get information about available HTTP libraries
    # @return [Hash] Hash with library names as keys and availability status as values
    def library_status
      {
        'Net::HTTP' => library_info_safe('Net::HTTP', 'net/http'),
        'Faraday' => library_info_safe('Faraday', 'faraday'),
        'HTTParty' => library_info_safe('HTTParty', 'httparty')
      }
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

        apply_patch_with_fallback('Net::HTTP', -> { Patches::NetHTTPPatch.apply! }, -> { defined?(Net::HTTP) })
        apply_patch_with_fallback('Faraday', -> { Patches::FaradayPatch.apply! }, -> { defined?(Faraday) })
        apply_patch_with_fallback('HTTParty', -> { Patches::HTTPartyPatch.apply! }, -> { defined?(HTTParty) })
      end

      # Apply a patch with graceful error handling and logging
      def apply_patch_with_fallback(library_name, patch_proc, availability_check)
        return unless availability_check.call

        patch_proc.call
        log_library_status(library_name, :patched)
      rescue StandardError => e
        log_library_status(library_name, :error, e)
        # Don't re-raise - continue with other patches
      end

      # Log the status of HTTP library availability and patching
      def log_library_status(library_name, status, error = nil)
        return unless configuration.debug_logging

        logger = configuration.get_logger
        return unless logger

        case status
        when :patched
          logger.debug("OutboundHTTPLogger: #{library_name} patch applied successfully")
        when :error
          logger.warn("OutboundHTTPLogger: Failed to patch #{library_name}: #{error.message}")
        end
      end

      # Get detailed information about a specific HTTP library (safe version using strings)
      def library_info_safe(library_name, gem_name)
        library_constant = begin
          Object.const_get(library_name)
        rescue NameError
          nil
        end

        if library_constant
          version = begin
            library_constant.const_get(:VERSION) if library_constant.const_defined?(:VERSION)
          rescue StandardError
            'unknown'
          end

          {
            available: true,
            version: version,
            patched: patch_applied_for_library_name?(library_name)
          }
        else
          {
            available: false,
            version: nil,
            patched: false,
            suggestion: "Add 'gem \"#{gem_name}\"' to your Gemfile to enable #{library_name} logging"
          }
        end
      rescue StandardError => e
        {
          available: false,
          version: nil,
          patched: false,
          error: e.message
        }
      end

      # Get detailed information about a specific HTTP library
      def library_info(library_constant, gem_name)
        if defined?(library_constant)
          version = begin
            library_constant.const_get(:VERSION) if library_constant.const_defined?(:VERSION)
          rescue StandardError
            'unknown'
          end

          {
            available: true,
            version: version,
            patched: patch_applied_for_library?(library_constant)
          }
        else
          {
            available: false,
            version: nil,
            patched: false,
            suggestion: "Add 'gem \"#{gem_name}\"' to your Gemfile to enable #{library_constant} logging"
          }
        end
      rescue StandardError => e
        {
          available: false,
          version: nil,
          patched: false,
          error: e.message
        }
      end

      # Check if patch has been applied for a specific library by name
      def patch_applied_for_library_name?(library_name)
        case library_name
        when 'Net::HTTP'
          Patches::NetHTTPPatch.applied?
        when 'Faraday'
          Patches::FaradayPatch.applied?
        when 'HTTParty'
          Patches::HTTPartyPatch.applied?
        else
          false
        end
      rescue StandardError
        false
      end

      # Check if patch has been applied for a specific library
      def patch_applied_for_library?(library_constant)
        case library_constant.name
        when 'Net::HTTP'
          Patches::NetHTTPPatch.applied?
        when 'Faraday'
          Patches::FaradayPatch.applied?
        when 'HTTParty'
          Patches::HTTPartyPatch.applied?
        else
          false
        end
      rescue StandardError
        false
      end

      # Apply patches immediately when libraries are available
      def apply_patches_if_needed
        setup_patches if configuration.enabled?
      end
  end
end

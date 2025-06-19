# frozen_string_literal: true

require "active_record"
require "active_support"

require_relative "outbound_http_logger/version"
require_relative "outbound_http_logger/configuration"
require_relative "outbound_http_logger/models/outbound_request_log"
require_relative "outbound_http_logger/concerns/outbound_logging"
require_relative "outbound_http_logger/patches/net_http_patch"
require_relative "outbound_http_logger/patches/faraday_patch"
require_relative "outbound_http_logger/patches/httparty_patch"
require_relative "outbound_http_logger/logger"
require_relative "outbound_http_logger/railtie" if defined?(Rails)

module OutboundHttpLogger
  class Error < StandardError; end

  class << self
    # Global configuration instance
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure the gem with a block
    def configure
      yield(configuration) if block_given?
      setup_patches if configuration.enabled?
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
    def enabled?
      configuration.enabled?
    end

    # Get the logger instance
    def logger
      @logger ||= Logger.new(configuration)
    end

    # Set metadata for the current thread's outbound requests
    def set_metadata(metadata)
      Thread.current[:outbound_http_logger_metadata] = metadata
    end

    # Set loggable for the current thread's outbound requests
    def set_loggable(loggable)
      Thread.current[:outbound_http_logger_loggable] = loggable
    end

    # Clear thread-local data
    def clear_thread_data
      Thread.current[:outbound_http_logger_metadata] = nil
      Thread.current[:outbound_http_logger_loggable] = nil
    end

    # Execute a block with specific loggable and metadata for outbound requests
    def with_logging(loggable: nil, metadata: {})
      # Store current values
      original_loggable = Thread.current[:outbound_http_logger_loggable]
      original_metadata = Thread.current[:outbound_http_logger_metadata]

      # Set new values
      set_loggable(loggable) if loggable
      set_metadata(metadata) if metadata.any?

      yield
    ensure
      # Restore original values
      Thread.current[:outbound_http_logger_loggable] = original_loggable
      Thread.current[:outbound_http_logger_metadata] = original_metadata
    end

    private

      # Set up HTTP library patches when enabled
      def setup_patches
        return unless configuration.enabled?

        Patches::NetHttpPatch.apply! if defined?(Net::HTTP)
        Patches::FaradayPatch.apply! if defined?(Faraday)
        Patches::HttppartyPatch.apply! if defined?(HTTParty)
      end

      # Apply patches immediately when libraries are available
      def apply_patches_if_needed
        setup_patches if configuration.enabled?
      end
  end
end

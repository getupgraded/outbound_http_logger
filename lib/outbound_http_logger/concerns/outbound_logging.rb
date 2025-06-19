# frozen_string_literal: true

module OutboundHttpLogger
  module Concerns
    module OutboundLogging
      extend ActiveSupport::Concern

      # Set a loggable object for outbound requests in the current thread
      def set_outbound_log_loggable(object)
        OutboundHttpLogger.set_loggable(object)
      end

      # Add custom metadata to outbound requests in the current thread
      def add_outbound_log_metadata(metadata)
        current_metadata = Thread.current[:outbound_http_logger_metadata] || {}
        OutboundHttpLogger.set_metadata(current_metadata.merge(metadata))
      end

      # Clear outbound logging thread data
      def clear_outbound_log_data
        OutboundHttpLogger.clear_thread_data
      end

      # Execute a block with specific loggable and metadata for outbound requests
      def with_outbound_logging(loggable: nil, metadata: {})
        # Store current values
        original_loggable = Thread.current[:outbound_http_logger_loggable]
        original_metadata = Thread.current[:outbound_http_logger_metadata]

        # Set new values
        OutboundHttpLogger.set_loggable(loggable) if loggable
        OutboundHttpLogger.set_metadata(metadata) if metadata.any?

        yield
      ensure
        # Restore original values
        Thread.current[:outbound_http_logger_loggable] = original_loggable
        Thread.current[:outbound_http_logger_metadata] = original_metadata
      end
    end
  end
end

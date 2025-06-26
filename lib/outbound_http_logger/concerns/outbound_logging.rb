# frozen_string_literal: true

module OutboundHTTPLogger
  module Concerns
    module OutboundLogging
      extend ActiveSupport::Concern

      # Set a loggable object for outbound requests in the current thread
      def set_outbound_log_loggable(object)
        OutboundHTTPLogger.set_loggable(object)
      end

      # Add custom metadata to outbound requests in the current thread
      def add_outbound_log_metadata(metadata)
        current_metadata = OutboundHTTPLogger::ThreadContext.metadata || {}
        OutboundHTTPLogger.set_metadata(current_metadata.merge(metadata))
      end

      # Clear outbound logging thread data
      def clear_outbound_log_data
        OutboundHTTPLogger.clear_thread_data
      end

      # Execute a block with specific loggable and metadata for outbound requests
      def with_outbound_logging(loggable: nil, metadata: {}, &)
        OutboundHTTPLogger::ThreadContext.with_context(loggable: loggable, metadata: metadata, &)
      end
    end
  end
end

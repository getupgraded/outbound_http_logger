# frozen_string_literal: true

module OutboundHTTPLogger
  module Concerns
    module OutboundLogging
      extend ActiveSupport::Concern

      # Set a loggable object for outbound requests in the current thread
      # @param object [Object] ActiveRecord model or other object to associate with requests
      # @return [void]
      # @example
      #   set_outbound_log_loggable(current_user)
      def set_outbound_log_loggable(object)
        OutboundHTTPLogger.set_loggable(object)
      end

      # Add custom metadata to outbound requests in the current thread
      # @param metadata [Hash] Metadata to merge with existing metadata
      # @return [void]
      # @example
      #   add_outbound_log_metadata(action: 'sync', source: 'manual')
      def add_outbound_log_metadata(metadata)
        current_metadata = OutboundHTTPLogger::ThreadContext.metadata || {}
        OutboundHTTPLogger.set_metadata(current_metadata.merge(metadata))
      end

      # Clear outbound logging thread data
      # @return [void]
      def clear_outbound_log_data
        OutboundHTTPLogger.clear_thread_data
      end

      # Execute a block with specific loggable and metadata for outbound requests
      # @param loggable [Object] Object to associate with outbound requests
      # @param metadata [Hash] Metadata to associate with outbound requests
      # @yield Block to execute with the specified context
      # @return [Object] Result of the yielded block
      # @example
      #   with_outbound_logging(loggable: order, metadata: { action: 'fulfillment' }) do
      #     HTTParty.post('https://api.example.com/orders', body: order.to_json)
      #   end
      def with_outbound_logging(loggable: nil, metadata: {}, &)
        OutboundHTTPLogger::ThreadContext.with_context(loggable: loggable, metadata: metadata, &)
      end
    end
  end
end

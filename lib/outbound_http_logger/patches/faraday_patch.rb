# frozen_string_literal: true

require_relative 'common_patch_behavior'

module OutboundHTTPLogger
  module Patches
    module FaradayPatch
      extend CommonPatchBehavior::ClassMethods

      def self.apply!
        # Check if Faraday is using Net::HTTP adapter
        unless using_net_http_adapter?
          warn_about_unsupported_adapter
          return
        end

        apply_patch_safely!(Faraday, Faraday::Connection, ConnectionMethods, 'Faraday')
      end

      # Check if Faraday is configured to use Net::HTTP adapter
      def self.using_net_http_adapter?
        return false unless defined?(Faraday)

        # Create a temporary connection to check the default adapter
        temp_connection = Faraday.new
        adapter_class = temp_connection.builder.adapter&.klass

        # Check if it's Net::HTTP or Net::HTTP-based adapter
        adapter_class&.name&.include?('NetHttp') || adapter_class&.name&.include?('Net::HTTP')
      rescue StandardError
        # If we can't determine the adapter, assume it's not Net::HTTP
        false
      end

      # Log warning about unsupported adapter
      def self.warn_about_unsupported_adapter
        config = OutboundHTTPLogger.configuration
        logger = config.get_logger

        return unless logger

        logger.warn(
          'OutboundHTTPLogger: Faraday patch skipped - Faraday is not using Net::HTTP adapter. ' \
          'Only Net::HTTP-based adapters are currently supported. ' \
          'Faraday requests will still be logged via Net::HTTP patch if the adapter uses Net::HTTP internally.'
        )
      end

      module ConnectionMethods
        include CommonPatchBehavior

        def run_request(method, url, body, headers, &)
          # Let Faraday handle URL building and capture the final URL from the response
          # This avoids method name collision with Faraday's private build_url method

          # Use common logging behavior - we'll get the final URL after the request
          log_http_request(
            'faraday',
            url.to_s, # Use the URL as-is initially, will be corrected in logging
            method.to_s.upcase,
            -> { { headers: headers || {}, body: body } },
            lambda { |response|
              {
                status_code: response.status,
                headers: response.headers.to_h,
                body: response.body,
                final_url: response.env.url.to_s # Capture the final resolved URL
              }
            },
            -> { super(method, url, body, headers, &) }
          )
        end
      end
    end
  end
end

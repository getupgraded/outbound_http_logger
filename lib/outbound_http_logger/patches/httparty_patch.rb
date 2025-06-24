# frozen_string_literal: true

module OutboundHttpLogger
  module Patches
    module HttppartyPatch
      def self.apply!
        return if @applied
        return unless defined?(HTTParty)

        # Patch HTTParty::Request
        HTTParty::Request.prepend(RequestMethods)
        @applied = true

        OutboundHttpLogger.configuration.get_logger&.debug("OutboundHttpLogger: HTTParty patch applied") if OutboundHttpLogger.configuration.debug_logging
      end

      module RequestMethods
        def perform(&block)
          # Early exit if logging is disabled
          return super unless OutboundHttpLogger.enabled?

          # Prevent infinite recursion
          return super if Thread.current[:outbound_http_logger_in_httparty]

          Thread.current[:outbound_http_logger_in_httparty] = true

          begin
            # Get the URL
            url = uri.to_s

            # Early exit if URL should be excluded
            return super unless OutboundHttpLogger.configuration.should_log_url?(url)

            # Capture request data
            request_data = {
              headers: options[:headers] || {},
              body: options[:body],
              loggable: Thread.current[:outbound_http_logger_loggable],
              metadata: Thread.current[:outbound_http_logger_metadata]
            }

            # Measure timing and make the request
            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            response   = super
            end_time   = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            # Capture response data
            response_data = {
              status_code: response.code,
              headers: response.headers.to_h,
              body: response.body
            }

            # Early exit if content type should be excluded
            content_type = response_data[:headers]['content-type'] || response_data[:headers]['Content-Type']
            return response unless OutboundHttpLogger.configuration.should_log_content_type?(content_type)

            # Log the request
            duration_seconds = end_time - start_time
            OutboundHttpLogger.logger.log_completed_request(
              http_method.name.split('::').last.upcase,
              url,
              request_data,
              response_data,
              duration_seconds
            )

            response
          rescue => e
            # Log failed requests too
            end_time         = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration_seconds = end_time - start_time

            # Ensure request_data is available for error logging
            request_data ||= {
              headers: options[:headers] || {},
              body: options[:body],
              loggable: Thread.current[:outbound_http_logger_loggable],
              metadata: Thread.current[:outbound_http_logger_metadata]
            }

            response_data = {
              status_code: 0,
              headers: {},
              body: "Error: #{e.class}: #{e.message}"
            }

            OutboundHttpLogger.logger.log_completed_request(
              http_method.name.split('::').last.upcase,
              url,
              request_data,
              response_data,
              duration_seconds
            )

            raise e
          ensure
            Thread.current[:outbound_http_logger_in_httparty] = false
          end
        end
      end
    end
  end
end

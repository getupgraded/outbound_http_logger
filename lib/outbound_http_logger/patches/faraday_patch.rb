# frozen_string_literal: true

module OutboundHttpLogger
  module Patches
    module FaradayPatch
      def self.apply!
        return if @applied
        return unless defined?(Faraday)

        # Patch Faraday::Connection
        Faraday::Connection.prepend(ConnectionMethods)
        @applied = true

        OutboundHttpLogger.configuration.get_logger&.debug("OutboundHttpLogger: Faraday patch applied") if OutboundHttpLogger.configuration.debug_logging
      end

      module ConnectionMethods
        def run_request(method, url, body, headers, &block)
          # Early exit if logging is disabled
          return super unless OutboundHttpLogger.enabled?

          # Prevent infinite recursion
          return super if Thread.current[:outbound_http_logger_in_faraday]

          Thread.current[:outbound_http_logger_in_faraday] = true

          begin
            # Build the full URL
            full_url = build_url(url)

            # Early exit if URL should be excluded
            return super unless OutboundHttpLogger.configuration.should_log_url?(full_url.to_s)

            # Capture request data
            request_data = {
              headers: headers || {},
              body: body,
              loggable: Thread.current[:outbound_http_logger_loggable],
              metadata: Thread.current[:outbound_http_logger_metadata]
            }

            # Measure timing and make the request
            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            response   = super
            end_time   = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            # Capture response data
            response_data = {
              status_code: response.status,
              headers: response.headers.to_h,
              body: response.body
            }

            # Early exit if content type should be excluded
            content_type = response_data[:headers]['content-type'] || response_data[:headers]['Content-Type']
            return response unless OutboundHttpLogger.configuration.should_log_content_type?(content_type)

            # Log the request
            duration_seconds = end_time - start_time
            OutboundHttpLogger.logger.log_completed_request(
              method.to_s.upcase,
              full_url.to_s,
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
              headers: headers || {},
              body: body,
              loggable: Thread.current[:outbound_http_logger_loggable],
              metadata: Thread.current[:outbound_http_logger_metadata]
            }

            response_data = {
              status_code: 0,
              headers: {},
              body: "Error: #{e.class}: #{e.message}"
            }

            OutboundHttpLogger.logger.log_completed_request(
              method.to_s.upcase,
              full_url.to_s,
              request_data,
              response_data,
              duration_seconds
            )

            raise e
          ensure
            Thread.current[:outbound_http_logger_in_faraday] = false
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module OutboundHttpLogger
  module Patches
    module NetHttpPatch
      def self.apply!
        return if @applied
        return unless defined?(Net::HTTP)

        Net::HTTP.prepend(InstanceMethods)
        @applied = true

        OutboundHttpLogger.configuration.get_logger&.debug("OutboundHttpLogger: Net::HTTP patch applied") if OutboundHttpLogger.configuration.debug_logging
      end

      module InstanceMethods
        def request(req, body = nil, &block)
          # Early exit if logging is disabled
          return super unless OutboundHttpLogger.enabled?

          # Prevent infinite recursion
          return super if Thread.current[:outbound_http_logger_in_request]

          Thread.current[:outbound_http_logger_in_request] = true

          begin
            # Build the full URL (omit default ports)
            scheme       = use_ssl? ? 'https' : 'http'
            default_port = use_ssl? ? 443 : 80
            port_part    = (port == default_port) ? '' : ":#{port}"
            url          = "#{scheme}://#{address}#{port_part}#{req.path}"

            # Early exit if URL should be excluded
            return super unless OutboundHttpLogger.configuration.should_log_url?(url)

            # Capture request data
            request_data = {
              headers: extract_request_headers(req),
              body: body || req.body,
              loggable: Thread.current[:outbound_http_logger_loggable],
              metadata: Thread.current[:outbound_http_logger_metadata]
            }

            # Measure timing and make the request
            start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            response   = super
            end_time   = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            # Capture response data
            response_data = {
              status_code: response.code.to_i,
              headers: extract_response_headers(response),
              body: response.body
            }

            # Early exit if content type should be excluded
            content_type = response_data[:headers]['content-type'] || response_data[:headers]['Content-Type']
            return response unless OutboundHttpLogger.configuration.should_log_content_type?(content_type)

            # Log the request
            duration_seconds = end_time - start_time
            OutboundHttpLogger.logger.log_completed_request(
              req.method,
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
              headers: extract_request_headers(req),
              body: body || req.body,
              loggable: Thread.current[:outbound_http_logger_loggable],
              metadata: Thread.current[:outbound_http_logger_metadata]
            }

            response_data = {
              status_code: 0,
              headers: {},
              body: "Error: #{e.class}: #{e.message}"
            }

            OutboundHttpLogger.logger.log_completed_request(
              req.method,
              url,
              request_data,
              response_data,
              duration_seconds
            )

            raise e
          ensure
            Thread.current[:outbound_http_logger_in_request] = false
          end
        end

        private

          def extract_request_headers(request)
            headers = {}
            request.each_header do |name, value|
              headers[name] = value
            end
            headers
          end

          def extract_response_headers(response)
            headers = {}
            response.each_header do |name, value|
              headers[name] = value
            end
            headers
          end
      end
    end
  end
end

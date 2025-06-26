# frozen_string_literal: true

module OutboundHTTPLogger
  module Patches
    module NetHTTPPatch
      @@applied = false

      def self.apply!
        # Simple one-time patch application (no mutex due to environment issues)
        return if @@applied
        return unless defined?(Net::HTTP)

        Net::HTTP.prepend(InstanceMethods)
        @@applied = true
        OutboundHTTPLogger.configuration.get_logger&.debug('OutboundHTTPLogger: Net::HTTP patch applied') if OutboundHTTPLogger.configuration.debug_logging
      end

      def self.applied?
        @@applied
      end

      def self.reset!
        @@applied = false
      end

      module InstanceMethods
        def request(req, body = nil, &)
          # Get configuration first to check if logging is enabled
          config = OutboundHTTPLogger.configuration

          # Early exit if logging is disabled
          return super unless config.enabled?

          library_name = 'net_http'

          # Check for recursion and prevent infinite loops
          if config.in_recursion?(library_name)
            config.check_recursion_depth!(library_name) if config.strict_recursion_detection
            return super
          end

          # Build the full URL (omit default ports)
          scheme       = use_ssl? ? 'https' : 'http'
          default_port = use_ssl? ? 443 : 80
          port_part    = port == default_port ? '' : ":#{port}"
          url          = "#{scheme}://#{address}#{port_part}#{req.path}"

          # Early exit if URL should be excluded (before setting recursion flag)
          return super unless config.should_log_url?(url)

          # Increment recursion depth with guaranteed cleanup
          config.increment_recursion_depth(library_name)

          begin
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

            # Check if content type should be excluded
            content_type = response_data[:headers]['content-type'] || response_data[:headers]['Content-Type']
            should_log_content_type = OutboundHTTPLogger.configuration.should_log_content_type?(content_type)

            # Log the request only if content type is allowed
            if should_log_content_type
              duration_seconds = end_time - start_time
              OutboundHTTPLogger.logger.log_completed_request(
                req.method,
                url,
                request_data,
                response_data,
                duration_seconds
              )
            end

            response
          rescue StandardError => e
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

            OutboundHTTPLogger.logger.log_completed_request(
              req.method,
              url,
              request_data,
              response_data,
              duration_seconds
            )

            raise e
          ensure
            config.decrement_recursion_depth(library_name)
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

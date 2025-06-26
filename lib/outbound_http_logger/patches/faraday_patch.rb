# frozen_string_literal: true

module OutboundHTTPLogger
  module Patches
    module FaradayPatch
      @mutex = Mutex.new
      @applied = false

      def self.apply!
        # Thread-safe patch application using mutex
        @mutex.synchronize do
          return if @applied
          return unless defined?(Faraday)

          # Patch Faraday::Connection
          Faraday::Connection.prepend(ConnectionMethods)
          @applied = true

          OutboundHTTPLogger.configuration.get_logger&.debug('OutboundHTTPLogger: Faraday patch applied') if OutboundHTTPLogger.configuration.debug_logging
        end
      end

      def self.applied?
        @mutex.synchronize { @applied }
      end

      def self.reset!
        @mutex.synchronize { @applied = false }
      end

      module ConnectionMethods
        def run_request(method, url, body, headers, &)
          # Get configuration first to check if logging is enabled
          config = OutboundHTTPLogger.configuration

          # Early exit if logging is disabled
          return super unless config.enabled?

          library_name = 'faraday'

          # Check for recursion and prevent infinite loops
          if config.in_recursion?(library_name)
            config.check_recursion_depth!(library_name) if config.strict_recursion_detection
            return super
          end

          # Build the full URL first (before setting recursion flag)
          full_url = build_url(url)

          # Early exit if URL should be excluded (before setting recursion flag)
          return super unless config.should_log_url?(full_url.to_s)

          # Increment recursion depth with guaranteed cleanup
          config.increment_recursion_depth(library_name)

          begin
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

            # Check if content type should be excluded
            content_type = response_data[:headers]['content-type'] || response_data[:headers]['Content-Type']
            should_log_content_type = OutboundHTTPLogger.configuration.should_log_content_type?(content_type)

            # Log the request only if content type is allowed
            if should_log_content_type
              duration_seconds = end_time - start_time
              OutboundHTTPLogger.logger.log_completed_request(
                method.to_s.upcase,
                full_url.to_s,
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

            OutboundHTTPLogger.logger.log_completed_request(
              method.to_s.upcase,
              full_url.to_s,
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

          def build_url(url)
            # If url is already absolute, return it as-is
            return url if url.to_s.start_with?('http://', 'https://')

            # Build URL from connection's base URL and the relative path
            base_url = url_prefix.to_s.chomp('/')
            relative_url = url.to_s.start_with?('/') ? url.to_s : "/#{url}"
            "#{base_url}#{relative_url}"
          end
      end
    end
  end
end

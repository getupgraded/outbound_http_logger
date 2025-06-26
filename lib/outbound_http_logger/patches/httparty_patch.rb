# frozen_string_literal: true

module OutboundHttpLogger
  module Patches
    module HTTPartyPatch
      @mutex = Mutex.new
      @applied = false

      def self.apply!
        # Thread-safe patch application using mutex
        @mutex.synchronize do
          return if @applied
          return unless defined?(HTTParty)

          # Patch HTTParty::Request
          HTTParty::Request.prepend(RequestMethods)
          @applied = true

          OutboundHttpLogger.configuration.get_logger&.debug('OutboundHttpLogger: HTTParty patch applied') if OutboundHttpLogger.configuration.debug_logging
        end
      end

      def self.applied?
        @mutex.synchronize { @applied }
      end

      def self.reset!
        @mutex.synchronize { @applied = false }
      end

      module RequestMethods
        def perform(&)
          # Get configuration first to check if logging is enabled
          config = OutboundHttpLogger.configuration

          # Early exit if logging is disabled
          return super unless config.enabled?

          library_name = 'httparty'

          # Check for recursion and prevent infinite loops
          if config.in_recursion?(library_name)
            config.check_recursion_depth!(library_name) if config.strict_recursion_detection
            return super
          end

          # Get the URL
          url = uri.to_s

          # Early exit if URL should be excluded (before setting recursion flag)
          return super unless config.should_log_url?(url)

          # Increment recursion depth with guaranteed cleanup
          config.increment_recursion_depth(library_name)

          begin
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

            # Check if content type should be excluded
            content_type = response_data[:headers]['content-type'] || response_data[:headers]['Content-Type']
            should_log_content_type = OutboundHttpLogger.configuration.should_log_content_type?(content_type)

            # Log the request only if content type is allowed
            if should_log_content_type
              duration_seconds = end_time - start_time
              OutboundHttpLogger.logger.log_completed_request(
                http_method.name.split('::').last.upcase,
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
            config.decrement_recursion_depth(library_name)
          end
        end
      end
    end
  end
end

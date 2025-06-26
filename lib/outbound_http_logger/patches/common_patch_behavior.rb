# frozen_string_literal: true

module OutboundHTTPLogger
  module Patches
    # Common behavior shared across all HTTP library patches
    # Provides standardized patch application, request logging, and error handling
    module CommonPatchBehavior
      # Module to be included in patch modules to provide common class methods
      module ClassMethods
        # Apply the patch with standard safety checks
        # @param library_constant [Class] The library class to check for existence
        # @param target_class [Class] The class to prepend the patch module to
        # @param patch_module [Module] The module containing the patch methods
        # @param library_name [String] Human-readable name for logging
        def apply_patch_safely!(library_constant, target_class, patch_module, library_name)
          return if applied?
          return unless defined?(library_constant)

          target_class.prepend(patch_module)
          mark_as_applied!
          log_patch_application(library_name)
        end

        # Check if patch has been applied
        def applied?
          @applied ||= false
        end

        # Mark patch as applied
        def mark_as_applied!
          @applied = true
        end

        # Reset patch application state (for testing)
        def reset!
          @applied = false
        end

        private

          def log_patch_application(library_name)
            config = OutboundHTTPLogger.configuration
            return unless config.debug_logging

            config.get_logger&.debug("OutboundHTTPLogger: #{library_name} patch applied")
          end
      end

      # Common request logging logic that can be used by all patches
      # @param library_name [String] Name of the HTTP library (e.g., 'net_http', 'faraday')
      # @param url [String] The request URL
      # @param method [String] The HTTP method
      # @param request_data_proc [Proc] Block that returns request data hash
      # @param response_data_proc [Proc] Block that returns response data hash
      # @param super_proc [Proc] Block that calls the original method
      def log_http_request(library_name, url, method, request_data_proc, response_data_proc, super_proc)
        config = OutboundHTTPLogger.configuration

        # Early exit if logging is disabled
        return super_proc.call unless config.enabled?

        # Check for recursion and prevent infinite loops
        if config.in_recursion?(library_name)
          config.check_recursion_depth!(library_name) if config.strict_recursion_detection
          return super_proc.call
        end

        # Early exit if URL should be excluded (before setting recursion flag)
        return super_proc.call unless config.should_log_url?(url)

        # Increment recursion depth with guaranteed cleanup
        config.increment_recursion_depth(library_name)

        begin
          # Capture request data
          request_data = build_request_data(request_data_proc.call)

          # Measure timing and make the request
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = super_proc.call
          end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # Capture response data
          response_data = response_data_proc.call(response)

          # Log successful request if content type is allowed
          log_successful_request(method, url, request_data, response_data, start_time, end_time)

          response
        rescue StandardError => e
          # Log failed requests
          end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          log_failed_request(method, url, request_data_proc.call, e, start_time, end_time)
          raise e
        ensure
          config.decrement_recursion_depth(library_name)
        end
      end

      private

        # Build standardized request data hash with thread-local context
        def build_request_data(library_specific_data)
          library_specific_data.merge(
            loggable: Thread.current[:outbound_http_logger_loggable],
            metadata: Thread.current[:outbound_http_logger_metadata]
          )
        end

        # Log successful HTTP request
        def log_successful_request(method, url, request_data, response_data, start_time, end_time)
          # Check if content type should be excluded
          content_type = extract_content_type(response_data[:headers])
          return unless OutboundHTTPLogger.configuration.should_log_content_type?(content_type)

          duration_seconds = end_time - start_time
          OutboundHTTPLogger.logger.log_completed_request(
            method,
            url,
            request_data,
            response_data,
            duration_seconds
          )
        end

        # Log failed HTTP request
        def log_failed_request(method, url, library_specific_data, error, start_time, end_time)
          duration_seconds = end_time - start_time
          request_data = build_request_data(library_specific_data)

          response_data = {
            status_code: 0,
            headers: {},
            body: "Error: #{error.class}: #{error.message}"
          }

          OutboundHTTPLogger.logger.log_completed_request(
            method,
            url,
            request_data,
            response_data,
            duration_seconds
          )
        end

        # Extract content type from response headers (handles case variations)
        def extract_content_type(headers)
          return nil unless headers

          headers['content-type'] || headers['Content-Type']
        end
    end
  end
end

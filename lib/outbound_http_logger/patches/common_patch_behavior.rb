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

          # Check if library is defined and accessible
          unless library_available?(library_constant)
            log_library_unavailable(library_name)
            return
          end

          # Verify target class is accessible
          unless target_class.respond_to?(:prepend)
            log_patch_error(library_name, "Target class #{target_class} does not support prepend")
            return
          end

          target_class.prepend(patch_module)
          mark_as_applied!
          log_patch_application(library_name)
        rescue StandardError => e
          log_patch_error(library_name, e.message)
          # Don't re-raise to allow other patches to be applied
        end

        # Check if a library is available and accessible
        def library_available?(library_constant)
          defined?(library_constant) && (library_constant.is_a?(Class) || library_constant.is_a?(Module))
        rescue StandardError
          false
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

            config.get_logger&.debug("OutboundHTTPLogger: #{library_name} patch applied successfully")
          end

          def log_library_unavailable(library_name)
            config = OutboundHTTPLogger.configuration
            return unless config.debug_logging

            config.get_logger&.debug("OutboundHTTPLogger: #{library_name} not available, skipping patch")
          end

          def log_patch_error(library_name, error_message)
            config = OutboundHTTPLogger.configuration
            logger = config.get_logger
            return unless logger

            return unless config.debug_logging

            logger.warn("OutboundHTTPLogger: Failed to patch #{library_name}: #{error_message}")
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

        # Early exit if this specific patch is disabled
        return super_proc.call unless patch_enabled_for_library?(library_name, config)

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
          # Capture request data and include library name in metadata
          request_data = build_request_data(request_data_proc.call, library_name)

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
          log_failed_request(method, url, request_data_proc.call, e, start_time, end_time, library_name)
          raise e
        ensure
          config.decrement_recursion_depth(library_name)
        end
      end

      private

        # Check if patch is enabled for a specific library
        # @param library_name [String] Library name (e.g., 'net_http', 'faraday')
        # @param config [Configuration] Configuration instance
        # @return [Boolean] true if patch is enabled for this library
        def patch_enabled_for_library?(library_name, config)
          case library_name.to_s.downcase
          when 'net_http'
            config.net_http_patch_enabled?
          when 'faraday'
            config.faraday_patch_enabled?
          else
            false
          end
        end

        # Build standardized request data hash with thread-local context
        def build_request_data(library_specific_data, library_name = nil)
          config = OutboundHTTPLogger.configuration

          # Detect calling library if enabled
          detected_library = library_name
          detected_library = detect_calling_library_from_stack || library_name if config.detect_calling_library? && library_name == 'net_http'

          # Merge thread-local metadata with library name
          thread_metadata = Thread.current[:outbound_http_logger_metadata] || {}
          merged_metadata = detected_library ? thread_metadata.merge(library: detected_library) : thread_metadata

          # Add call stack if debug logging is enabled
          merged_metadata = merged_metadata.merge(call_stack: capture_call_stack) if config.debug_call_stack_logging?

          library_specific_data.merge(
            loggable: Thread.current[:outbound_http_logger_loggable],
            metadata: merged_metadata
          )
        end

        # Detect the calling library from the call stack
        def detect_calling_library_from_stack
          caller_locations.each do |location|
            path = location.path

            # Check for known HTTP libraries in the call stack
            return 'httparty' if path.include?('httparty')
            return 'faraday' if path.include?('faraday')
            return 'rest-client' if path.include?('rest-client') || path.include?('restclient')
            return 'typhoeus' if path.include?('typhoeus')
            return 'patron' if path.include?('patron')
            return 'excon' if path.include?('excon')
            return 'httpclient' if path.include?('httpclient')
          end

          nil # Return nil if no known library is detected
        end

        # Capture call stack for debugging
        def capture_call_stack
          caller_locations.map do |location|
            "#{location.path}:#{location.lineno}:in `#{location.label}'"
          end
        end

        # Log successful HTTP request with standardized error handling
        def log_successful_request(method, url, request_data, response_data, start_time, end_time)
          OutboundHTTPLogger::ErrorHandling.handle_logging_error('log successful request') do
            # Check if content type should be excluded
            content_type = extract_content_type(response_data[:headers])
            return unless OutboundHTTPLogger.configuration.should_log_content_type?(content_type)

            # Use final_url from response if available (for Faraday), otherwise use original URL
            final_url = response_data.delete(:final_url) || url

            duration_seconds = end_time - start_time
            duration_ms = (duration_seconds * 1000).round(2)
            OutboundHTTPLogger.logger.log_completed_request(
              method,
              final_url,
              request_data,
              response_data,
              duration_ms
            )
          end
        end

        # Log failed HTTP request with standardized error handling
        def log_failed_request(method, url, library_specific_data, error, start_time, end_time, library_name = nil)
          OutboundHTTPLogger::ErrorHandling.handle_logging_error('log failed request') do
            duration_seconds = end_time - start_time
            duration_ms = (duration_seconds * 1000).round(2)
            request_data = build_request_data(library_specific_data, library_name)

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
              duration_ms
            )
          end
        end

        # Extract content type from response headers (handles case variations)
        def extract_content_type(headers)
          return nil unless headers

          headers['content-type'] || headers['Content-Type']
        end
    end
  end
end

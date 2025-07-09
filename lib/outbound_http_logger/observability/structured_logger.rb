# frozen_string_literal: true

require 'json'
require 'securerandom'

module OutboundHTTPLogger
  module Observability
    # Structured logger that provides JSON and key-value formatted logging
    # with automatic context injection and performance tracking
    class StructuredLogger
      # Log levels in order of severity
      LOG_LEVELS = {
        debug: 0,
        info: 1,
        warn: 2,
        error: 3,
        fatal: 4
      }.freeze

      attr_reader :configuration, :underlying_logger, :format

      # Initialize structured logger
      # @param configuration [Configuration] OutboundHTTPLogger configuration
      # @param underlying_logger [Logger] Rails logger or custom logger
      # @param format [Symbol] :json or :key_value
      def initialize(configuration, underlying_logger = nil, format = :json)
        @configuration = configuration
        @underlying_logger = underlying_logger || default_logger
        @format = format
        @mutex = Mutex.new
        @context_stack = []

        # Configure the underlying logger to output raw messages
        configure_underlying_logger
      end

      # Main logging method with structured format
      # @param level [Symbol] Log level (:debug, :info, :warn, :error, :fatal)
      # @param message [String] Log message
      # @param context [Hash] Additional context data
      # @return [void]
      def log(level, message, context = {})
        return unless should_log?(level)

        formatted_message = format_message(level, message, context)
        @underlying_logger.send(level, formatted_message)
      end

      # Convenience methods for each log level
      LOG_LEVELS.each_key do |level|
        define_method(level) do |message, context = {}|
          log(level, message, context)
        end
      end

      # Execute block with additional context
      # @param context [Hash] Context to add for the duration of the block
      # @yield Block to execute with additional context
      # @return [Object] Result of the yielded block
      def with_context(context = {})
        @mutex.synchronize { @context_stack.push(context) }
        yield
      ensure
        @mutex.synchronize { @context_stack.pop }
      end

      # Log performance information for operations above threshold
      # @param operation [String] Name of the operation
      # @param duration [Float] Duration in seconds
      # @param context [Hash] Additional context
      # @return [void]
      def performance_log(operation, duration, context = {})
        threshold = @configuration.performance_logging_threshold || 1.0
        return unless duration >= threshold

        perf_context = context.merge(
          operation: operation,
          duration_seconds: duration,
          performance_warning: duration >= threshold * 2
        )

        level = duration >= threshold * 2 ? :warn : :info
        log(level, "Slow operation detected: #{operation}", perf_context)
      end

      # Log database operation with timing
      # @param operation [String] Database operation name
      # @param duration [Float] Duration in seconds
      # @param context [Hash] Additional context
      # @return [void]
      def database_operation(operation, duration, context = {})
        db_context = context.merge(
          category: 'database',
          operation: operation,
          duration_seconds: duration
        )

        debug("Database operation: #{operation}", db_context)
        performance_log("database.#{operation}", duration, db_context)
      end

      # Log HTTP request with structured data
      # @param method [String] HTTP method
      # @param url [String] Request URL
      # @param status_code [Integer] Response status code
      # @param duration [Float] Request duration in seconds
      # @param context [Hash] Additional context
      # @return [void]
      def http_request(method, url, status_code, duration, context = {})
        http_context = context.merge(
          category: 'http_request',
          method: method.to_s.upcase,
          url: sanitize_url(url),
          status_code: status_code,
          duration_seconds: duration,
          success: (200..299).cover?(status_code.to_i)
        )

        level = determine_http_log_level(status_code)
        log(level, "HTTP #{method.upcase} #{sanitize_url(url)} #{status_code}", http_context)
      end

      # Log configuration changes
      # @param setting [String] Configuration setting name
      # @param old_value [Object] Previous value
      # @param new_value [Object] New value
      # @param context [Hash] Additional context
      # @return [void]
      def configuration_change(setting, old_value, new_value, context = {})
        config_context = context.merge(
          category: 'configuration',
          setting: setting,
          old_value: old_value,
          new_value: new_value
        )

        info("Configuration changed: #{setting}", config_context)
      end

      # Log error with structured format and stack trace
      # @param error [Exception] Error to log
      # @param context [Hash] Additional context
      # @return [void]
      def error_with_context(error, context = {})
        error_context = context.merge(
          category: 'error',
          error_class: error.class.name,
          error_message: error.message,
          backtrace: error.backtrace&.first(10)
        )

        error("#{error.class}: #{error.message}", error_context)
      end

      private

        # Check if we should log at the given level
        # @param level [Symbol] Log level to check
        # @return [Boolean] true if should log
        def should_log?(level)
          return false unless @configuration.structured_logging_enabled?

          current_level = @configuration.structured_logging_level || :info
          LOG_LEVELS[level] >= LOG_LEVELS[current_level]
        end

        # Format message according to configured format
        # @param level [Symbol] Log level
        # @param message [String] Log message
        # @param context [Hash] Context data
        # @return [String] Formatted message
        def format_message(level, message, context)
          full_context = build_full_context(level, message, context)

          case @format
          when :json
            JSON.generate(full_context)
          when :key_value
            format_key_value(full_context)
          else
            # Fallback to simple format
            "#{full_context[:timestamp]} [#{level.upcase}] #{message}"
          end
        end

        # Build complete context with automatic fields
        # @param level [Symbol] Log level
        # @param message [String] Log message
        # @param context [Hash] User-provided context
        # @return [Hash] Complete context
        def build_full_context(level, message, context)
          base_context = {
            timestamp: Time.current.iso8601(3),
            level: level.to_s.upcase,
            message: message,
            thread_id: Thread.current.object_id,
            gem_version: OutboundHTTPLogger::VERSION
          }

          # Add request ID if available
          base_context[:request_id] = ThreadContext.metadata[:request_id] if ThreadContext.metadata&.dig(:request_id)

          # Add current context stack
          @mutex.synchronize do
            @context_stack.each { |ctx| base_context.merge!(ctx) }
          end

          # Add user-provided context
          base_context.merge!(context)

          base_context
        end

        # Format context as key-value pairs
        # @param context [Hash] Context to format
        # @return [String] Key-value formatted string
        def format_key_value(context)
          pairs = context.map do |key, value|
            formatted_value = value.is_a?(String) ? value : value.inspect
            "#{key}=#{formatted_value}"
          end
          pairs.join(' ')
        end

        # Determine appropriate log level for HTTP status code
        # @param status_code [Integer] HTTP status code
        # @return [Symbol] Log level
        def determine_http_log_level(status_code)
          case status_code.to_i
          when 200..299 then :info
          when 300..399 then :info # rubocop:disable Lint/DuplicateBranch
          when 400..499 then :warn
          when 500..599 then :error
          else :debug
          end
        end

        # Sanitize URL for logging (remove sensitive parameters)
        # @param url [String] URL to sanitize
        # @return [String] Sanitized URL
        def sanitize_url(url)
          return url unless url.is_a?(String)

          # Remove common sensitive parameters
          uri = URI.parse(url)
          if uri.query
            params = URI.decode_www_form(uri.query)
            sanitized_params = params.reject { |key, _| sensitive_param?(key) }
            uri.query = URI.encode_www_form(sanitized_params)
          end
          uri.to_s
        rescue URI::InvalidURIError
          url # Return original if parsing fails
        end

        # Check if parameter name is sensitive
        # @param param_name [String] Parameter name
        # @return [Boolean] true if sensitive
        def sensitive_param?(param_name)
          sensitive_patterns = %w[
            password token secret key api_key access_token
            auth authorization credential
          ]
          param_name.to_s.downcase.match?(Regexp.union(sensitive_patterns))
        end

        # Configure the underlying logger for structured output
        # @return [void]
        def configure_underlying_logger
          return unless @underlying_logger.respond_to?(:formatter=)

          # Set a simple formatter that just outputs the message
          @underlying_logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
        end

        # Get default logger
        # @return [Logger] Default logger instance
        def default_logger
          logger = if defined?(Rails) && Rails.logger.is_a?(::Logger)
                     Rails.logger.dup
                   else
                     ::Logger.new($stdout)
                   end

          # Ensure we have a clean logger for structured output
          if logger.respond_to?(:formatter=)
            logger.formatter = proc { |_severity, _datetime, _progname, msg|
              "#{msg}\n"
            }
          end
          logger
        end
    end
  end
end

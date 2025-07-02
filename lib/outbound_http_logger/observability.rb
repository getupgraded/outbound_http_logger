# frozen_string_literal: true

require_relative 'observability/structured_logger'
require_relative 'observability/metrics_collector'
require_relative 'observability/debug_tools'

module OutboundHTTPLogger
  # Observability module providing structured logging, metrics collection, and debugging tools
  module Observability
    class << self
      attr_reader :structured_logger, :metrics_collector, :debug_tools

      # Initialize observability components
      # @param configuration [Configuration] OutboundHTTPLogger configuration
      # @return [void]
      def initialize!(configuration)
        @configuration = configuration
        @structured_logger = StructuredLogger.new(configuration)
        @metrics_collector = MetricsCollector.new(configuration)
        @debug_tools = DebugTools.new(configuration)
      end

      # Get current configuration
      # @return [Configuration] Current configuration
      attr_reader :configuration

      # Log structured message
      # @param level [Symbol] Log level
      # @param message [String] Log message
      # @param context [Hash] Additional context
      # @return [void]
      def log(level, message, context = {})
        @structured_logger&.log(level, message, context)
      end

      # Convenience methods for each log level
      %i[debug info warn error fatal].each do |level|
        define_method(level) do |message, context = {}|
          log(level, message, context)
        end
      end

      # Record HTTP request metrics and logging
      # @param method [String] HTTP method
      # @param url [String] Request URL
      # @param status_code [Integer] Response status code
      # @param duration [Float] Request duration in seconds
      # @param error [Exception, nil] Error if request failed
      # @param context [Hash] Additional context
      # @return [void]
      def record_http_request(method, url, status_code, duration, error = nil, context = {})
        # Record metrics
        begin
          @metrics_collector&.record_http_request(method, url, status_code, duration, error)
        rescue StandardError => e
          handle_observability_error('metrics collection', e)
        end

        # Log structured data
        begin
          @structured_logger&.http_request(method, url, status_code, duration, context)
        rescue StandardError => e
          handle_observability_error('structured logging', e)
        end

        # Add trace event if tracing is active
        begin
          @debug_tools&.trace_event('http_request', {
            method: method,
            url: url,
            status_code: status_code,
            duration_seconds: duration,
            error: error&.class&.name
          }.merge(context))
        rescue StandardError => e
          handle_observability_error('trace event', e)
        end
      end

      # Record database operation metrics and logging
      # @param operation [String] Database operation
      # @param duration [Float] Operation duration in seconds
      # @param error [Exception, nil] Error if operation failed
      # @param context [Hash] Additional context
      # @return [void]
      def record_database_operation(operation, duration, error = nil, context = {})
        # Record metrics
        @metrics_collector&.record_database_operation(operation, duration, error)

        # Log structured data
        @structured_logger&.database_operation(operation, duration, context)

        # Add trace event if tracing is active
        @debug_tools&.trace_event('database_operation', {
          operation: operation,
          duration_seconds: duration,
          error: error&.class&.name
        }.merge(context))
      end

      # Execute block with observability (tracing, profiling, metrics)
      # @param operation [String] Operation name
      # @param context [Hash] Initial context
      # @yield Block to execute with observability
      # @return [Object] Result of the yielded block
      def with_observability(operation, context = {}, &)
        return yield unless observability_enabled?

        @debug_tools.with_trace(operation, context) do
          @debug_tools.profile(operation, context, &)
        end
      end

      # Execute block with additional logging context
      # @param context [Hash] Context to add
      # @yield Block to execute with context
      # @return [Object] Result of the yielded block
      def with_context(context = {}, &)
        return yield unless @structured_logger

        @structured_logger.with_context(context, &)
      end

      # Get current metrics snapshot
      # @return [Hash] Current metrics data
      def metrics_snapshot
        @metrics_collector&.snapshot || {}
      end

      # Export metrics in Prometheus format
      # @return [String] Prometheus-formatted metrics
      def metrics_prometheus
        @metrics_collector&.to_prometheus || ''
      end

      # Get health check information
      # @return [Hash] Health check results
      def health_check
        @debug_tools&.health_check || { status: 'unknown', message: 'Debug tools not initialized' }
      end

      # Validate configuration
      # @return [Hash] Validation results
      def validate_configuration
        @debug_tools&.validate_configuration || { valid: false, errors: ['Debug tools not initialized'] }
      end

      # Get memory analysis
      # @return [Hash] Memory usage information
      def memory_analysis
        @debug_tools&.memory_analysis || {}
      end

      # Get active traces
      # @return [Array] Active trace summaries
      def active_traces
        @debug_tools&.active_traces || []
      end

      # Record memory usage metrics
      # @return [void]
      def record_memory_usage
        @metrics_collector&.record_memory_usage
      end

      # Reset all metrics (useful for testing)
      # @return [void]
      def reset_metrics!
        @metrics_collector&.reset!
      end

      # Log configuration change
      # @param setting [String] Configuration setting name
      # @param old_value [Object] Previous value
      # @param new_value [Object] New value
      # @param context [Hash] Additional context
      # @return [void]
      def log_configuration_change(setting, old_value, new_value, context = {})
        @structured_logger&.configuration_change(setting, old_value, new_value, context)
      end

      # Log error with full context
      # @param error [Exception] Error to log
      # @param context [Hash] Additional context
      # @return [void]
      def log_error(error, context = {})
        @structured_logger&.error_with_context(error, context)

        # Also add to trace if active
        @debug_tools&.trace_event('error', {
          error_class: error.class.name,
          error_message: error.message
        }.merge(context))
      end

      # Check if observability is enabled
      # @return [Boolean] true if any observability feature is enabled
      def observability_enabled?
        return false unless @configuration

        @configuration.structured_logging_enabled? ||
          @configuration.metrics_collection_enabled? ||
          @configuration.debug_tools_enabled?
      end

      # Check if structured logging is enabled
      # @return [Boolean] true if structured logging is enabled
      def structured_logging_enabled?
        @configuration&.structured_logging_enabled? || false
      end

      # Check if metrics collection is enabled
      # @return [Boolean] true if metrics collection is enabled
      def metrics_collection_enabled?
        @configuration&.metrics_collection_enabled? || false
      end

      # Check if debug tools are enabled
      # @return [Boolean] true if debug tools are enabled
      def debug_tools_enabled?
        @configuration&.debug_tools_enabled? || false
      end

      # Start a new trace
      # @param operation [String] Operation name
      # @param context [Hash] Initial context
      # @return [String, nil] Trace ID
      def start_trace(operation, context = {})
        @debug_tools&.start_trace(operation, context)
      end

      # End a trace
      # @param trace_id [String] Trace ID to end
      # @param result [Hash] Final result data
      # @return [Hash, nil] Trace summary
      def end_trace(trace_id, result = {})
        @debug_tools&.end_trace(trace_id, result)
      end

      # Add event to current trace
      # @param event_name [String] Event name
      # @param data [Hash] Event data
      # @param trace_id [String, nil] Specific trace ID (uses current if nil)
      # @return [void]
      def trace_event(event_name, data = {}, trace_id = nil)
        @debug_tools&.trace_event(event_name, data, trace_id)
      end

      # Profile a block of code
      # @param operation [String] Operation name
      # @param context [Hash] Additional context
      # @yield Block to profile
      # @return [Object] Result of the yielded block
      def profile(operation, context = {}, &)
        return yield unless @debug_tools

        @debug_tools.profile(operation, context, &)
      end

      # Increment a counter metric
      # @param name [String] Counter name
      # @param value [Integer] Value to add
      # @param tags [Hash] Additional tags
      # @return [void]
      def increment_counter(name, value = 1, tags = {})
        @metrics_collector&.increment_counter(name, value, tags)
      end

      # Record a histogram value
      # @param name [String] Histogram name
      # @param value [Float] Value to record
      # @param tags [Hash] Additional tags
      # @return [void]
      def record_histogram(name, value, tags = {})
        @metrics_collector&.record_histogram(name, value, tags)
      end

      # Set a gauge value
      # @param name [String] Gauge name
      # @param value [Numeric] Current value
      # @param tags [Hash] Additional tags
      # @return [void]
      def set_gauge(name, value, tags = {})
        @metrics_collector&.set_gauge(name, value, tags)
      end

      private

        # Handle observability errors gracefully
        # @param operation [String] Operation that failed
        # @param error [Exception] Error that occurred
        # @return [void]
        def handle_observability_error(operation, error)
          # Don't let observability errors break the main application flow
          # Only log if debug logging is enabled and we have a logger
          return unless @configuration&.debug_logging && @configuration.logger

          begin
            @configuration.logger.error("Observability #{operation} error: #{error.class}: #{error.message}")
          rescue StandardError
            # If even logging fails, silently ignore to prevent infinite loops
          end
        end
    end
  end
end

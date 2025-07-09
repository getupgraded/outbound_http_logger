# frozen_string_literal: true

require 'securerandom'
require 'benchmark'

module OutboundHTTPLogger
  module Observability
    # Debug tools for troubleshooting and performance analysis
    class DebugTools
      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
        @active_traces = {}
        @mutex = Mutex.new
      end

      # Start a new request trace
      # @param operation [String] Operation name
      # @param context [Hash] Initial context
      # @return [String] Trace ID
      def start_trace(operation, context = {})
        return nil unless enabled?

        trace_id = SecureRandom.uuid
        trace_data = {
          id: trace_id,
          operation: operation,
          started_at: Time.current,
          context: context.dup,
          events: [],
          parent_trace: current_trace_id
        }

        @mutex.synchronize { @active_traces[trace_id] = trace_data }

        # Set as current trace in thread context
        ThreadContext.metadata = (ThreadContext.metadata || {}).merge(trace_id: trace_id)

        log_trace_event(trace_id, 'trace_started', { operation: operation })
        trace_id
      end

      # End a trace
      # @param trace_id [String] Trace ID to end
      # @param result [Hash] Final result data
      # @return [Hash, nil] Trace summary
      def end_trace(trace_id, result = {})
        return nil unless enabled? && trace_id

        trace = nil
        duration = nil

        @mutex.synchronize do
          trace = @active_traces.delete(trace_id)
          return nil unless trace

          duration = Time.current - trace[:started_at]

          # Clear from thread context if this was the current trace
          ThreadContext.metadata = ThreadContext.metadata.except(:trace_id) if ThreadContext.metadata&.dig(:trace_id) == trace_id
        end

        # Log trace event outside of mutex to avoid deadlock
        log_trace_event(trace_id, 'trace_completed', {
                          duration_seconds: duration,
                          result: result
                        })

        trace.merge(
          completed_at: Time.current,
          duration_seconds: duration,
          result: result
        )
      end

      # Add event to current or specified trace
      # @param event_name [String] Event name
      # @param data [Hash] Event data
      # @param trace_id [String, nil] Specific trace ID (uses current if nil)
      # @return [void]
      def trace_event(event_name, data = {}, trace_id = nil)
        return unless enabled?

        trace_id ||= current_trace_id
        return unless trace_id

        log_trace_event(trace_id, event_name, data)
      end

      # Execute block with tracing
      # @param operation [String] Operation name
      # @param context [Hash] Initial context
      # @yield Block to execute with tracing
      # @return [Object] Result of the yielded block
      def with_trace(operation, context = {})
        return yield unless enabled?

        trace_id = start_trace(operation, context)

        begin
          result = yield
          end_trace(trace_id, { success: true, result_class: result.class.name })
          result
        rescue StandardError => e
          end_trace(trace_id, {
                      success: false,
                      error: e.class.name,
                      error_message: e.message
                    })
          raise
        end
      end

      # Profile a block of code
      # @param operation [String] Operation name
      # @param context [Hash] Additional context
      # @yield Block to profile
      # @return [Object] Result of the yielded block
      def profile(operation, context = {})
        return yield unless enabled?

        start_time = monotonic_time
        memory_before = current_memory_usage

        begin
          result = yield

          duration = monotonic_time - start_time
          memory_after = current_memory_usage
          memory_delta = memory_after - memory_before

          profile_data = context.merge(
            operation: operation,
            duration_seconds: duration,
            memory_before_mb: memory_before,
            memory_after_mb: memory_after,
            memory_delta_mb: memory_delta
          )

          structured_logger&.performance_log(operation, duration, profile_data)
          trace_event('performance_profile', profile_data)

          result
        rescue StandardError => e
          duration = monotonic_time - start_time

          error_data = context.merge(
            operation: operation,
            duration_seconds: duration,
            error: e.class.name,
            error_message: e.message
          )

          structured_logger&.error_with_context(e, error_data)
          trace_event('performance_profile_error', error_data)

          raise
        end
      end

      # Validate current configuration
      # @return [Hash] Validation results
      def validate_configuration
        results = {
          valid: true,
          warnings: [],
          errors: [],
          recommendations: []
        }

        # Check database configuration
        validate_database_config(results)

        # Check performance settings
        validate_performance_settings(results)

        # Check security settings
        validate_security_settings(results)

        # Check observability settings
        validate_observability_settings(results)

        results[:valid] = results[:errors].empty?
        results
      end

      # Get health check information
      # @return [Hash] Health check results
      def health_check
        health = {
          status: 'healthy',
          timestamp: Time.current.iso8601,
          checks: {}
        }

        # Database connectivity
        health[:checks][:database] = check_database_health

        # Memory usage
        health[:checks][:memory] = check_memory_health

        # Configuration
        health[:checks][:configuration] = check_configuration_health

        # Thread context
        health[:checks][:thread_context] = check_thread_context_health

        # Determine overall status
        failed_checks = health[:checks].values.count { |check| check[:status] != 'healthy' }
        health[:status] = failed_checks.positive? ? 'unhealthy' : 'healthy'

        health
      end

      # Get current active traces
      # @return [Array] Active trace summaries
      def active_traces
        return [] unless enabled?

        @mutex.synchronize do
          @active_traces.values.map do |trace|
            {
              id: trace[:id],
              operation: trace[:operation],
              started_at: trace[:started_at],
              duration_so_far: Time.current - trace[:started_at],
              event_count: trace[:events].size,
              context: trace[:context]
            }
          end
        end
      end

      # Get memory usage analysis
      # @return [Hash] Memory usage information
      def memory_analysis
        analysis = {
          current_usage_mb: current_memory_usage,
          timestamp: Time.current.iso8601
        }

        if defined?(GC)
          gc_stat = GC.stat
          analysis[:gc_stats] = {
            heap_live_slots: gc_stat[:heap_live_slots],
            heap_free_slots: gc_stat[:heap_free_slots],
            total_allocated_objects: gc_stat[:total_allocated_objects],
            major_gc_count: gc_stat[:major_gc_count],
            minor_gc_count: gc_stat[:minor_gc_count]
          }
        end

        analysis[:object_counts] = ObjectSpace.count_objects if defined?(ObjectSpace)

        analysis
      end

      private

        # Check if debug tools are enabled
        # @return [Boolean] true if enabled
        def enabled?
          @configuration.debug_tools_enabled?
        end

        # Get current trace ID from thread context
        # @return [String, nil] Current trace ID
        def current_trace_id
          ThreadContext.metadata&.dig(:trace_id)
        end

        # Log trace event
        # @param trace_id [String] Trace ID
        # @param event_name [String] Event name
        # @param data [Hash] Event data
        # @return [void]
        def log_trace_event(trace_id, event_name, data)
          @mutex.synchronize do
            trace = @active_traces[trace_id]
            return unless trace

            event = {
              name: event_name,
              timestamp: Time.current,
              data: data.dup
            }

            trace[:events] << event
          end

          # Also log to structured logger if available
          structured_logger&.debug("Trace event: #{event_name}", {
            trace_id: trace_id,
            event: event_name
          }.merge(data))
        end

        # Get monotonic time for accurate duration measurement
        # @return [Float] Monotonic time in seconds
        def monotonic_time
          if defined?(Process::CLOCK_MONOTONIC)
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          else
            Time.now.to_f
          end
        end

        # Get current memory usage in MB
        # @return [Float] Memory usage in MB
        def current_memory_usage
          if File.exist?('/proc/self/status')
            memory_kb = File.read('/proc/self/status')[/VmRSS:\s*(\d+)/, 1]
            return memory_kb.to_f / 1024 if memory_kb
          end

          # Fallback for non-Linux systems
          if defined?(GC)
            # Rough estimation based on heap slots
            gc_stat = GC.stat
            (gc_stat[:heap_live_slots] * 40) / (1024 * 1024).to_f # Assume ~40 bytes per slot
          else
            0.0
          end
        end

        # Get structured logger instance
        # @return [StructuredLogger, nil] Logger instance
        def structured_logger
          OutboundHTTPLogger.observability&.structured_logger
        end

        # Validate database configuration
        # @param results [Hash] Results hash to update
        # @return [void]
        def validate_database_config(results)
          results[:warnings] << 'No secondary database URL configured - using primary database' unless @configuration.secondary_database_url

          adapter = @configuration.secondary_database_adapter
          return if %i[sqlite postgresql].include?(adapter)

          results[:errors] << "Unsupported database adapter: #{adapter}"
        end

        # Validate performance settings
        # @param results [Hash] Results hash to update
        # @return [void]
        def validate_performance_settings(results)
          results[:warnings] << "Large max_body_size (#{@configuration.max_body_size}) may impact performance" if @configuration.max_body_size > 100_000

          return unless @configuration.performance_logging_threshold && @configuration.performance_logging_threshold < 0.1

          results[:recommendations] << 'Consider increasing performance_logging_threshold for production'
        end

        # Validate security settings
        # @param results [Hash] Results hash to update
        # @return [void]
        def validate_security_settings(results)
          results[:warnings] << 'No sensitive headers configured - consider adding Authorization, Cookie, etc.' if @configuration.sensitive_headers.empty?

          return unless @configuration.sensitive_body_keys.empty?

          results[:warnings] << 'No sensitive body keys configured - consider adding password, token, etc.'
        end

        # Validate observability settings
        # @param results [Hash] Results hash to update
        # @return [void]
        def validate_observability_settings(results)
          results[:recommendations] << 'Enable structured logging for better observability' unless @configuration.structured_logging_enabled?

          return if @configuration.metrics_collection_enabled?

          results[:recommendations] << 'Enable metrics collection for performance monitoring'
        end

        # Check database health
        # @return [Hash] Database health check result
        def check_database_health
          # Try to access the database adapter
          adapter = OutboundHTTPLogger.database_adapter
          if adapter&.enabled?
            { status: 'healthy', message: 'Database adapter available and enabled' }
          else
            { status: 'warning', message: 'Database adapter not enabled' }
          end
        rescue StandardError => e
          { status: 'unhealthy', message: "Database error: #{e.message}" }
        end

        # Check memory health
        # @return [Hash] Memory health check result
        def check_memory_health
          usage_mb = current_memory_usage

          if usage_mb > 500 # 500MB threshold
            { status: 'warning', message: "High memory usage: #{usage_mb.round(2)}MB" }
          else
            { status: 'healthy', message: "Memory usage: #{usage_mb.round(2)}MB" }
          end
        end

        # Check configuration health
        # @return [Hash] Configuration health check result
        def check_configuration_health
          validation = validate_configuration

          if validation[:errors].any?
            { status: 'unhealthy', message: "Configuration errors: #{validation[:errors].join(', ')}" }
          elsif validation[:warnings].any?
            { status: 'warning', message: "Configuration warnings: #{validation[:warnings].join(', ')}" }
          else
            { status: 'healthy', message: 'Configuration valid' }
          end
        end

        # Check thread context health
        # @return [Hash] Thread context health check result
        def check_thread_context_health
          active_count = active_traces.size

          if active_count > 100
            { status: 'warning', message: "Many active traces: #{active_count}" }
          else
            { status: 'healthy', message: "Active traces: #{active_count}" }
          end
        end
    end
  end
end

# frozen_string_literal: true

module OutboundHTTPLogger
  module Observability
    # Thread-safe metrics collector for tracking HTTP requests and performance
    class MetricsCollector
      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
        @mutex = Mutex.new
        @counters = Hash.new(0)
        @histograms = Hash.new { |h, k| h[k] = [] }
        @gauges = {}
        @start_time = Time.current
      end

      # Record a counter increment
      # @param name [String] Counter name
      # @param value [Integer] Value to add (default: 1)
      # @param tags [Hash] Additional tags
      # @return [void]
      def increment_counter(name, value = 1, tags = {})
        return unless enabled?

        key = build_metric_key(name, tags)
        @mutex.synchronize { @counters[key] += value }
      end

      # Record a histogram value (for durations, sizes, etc.)
      # @param name [String] Histogram name
      # @param value [Float] Value to record
      # @param tags [Hash] Additional tags
      # @return [void]
      def record_histogram(name, value, tags = {})
        return unless enabled?

        key = build_metric_key(name, tags)
        @mutex.synchronize do
          @histograms[key] << value
          # Keep only last 1000 values to prevent memory growth
          @histograms[key] = @histograms[key].last(1000) if @histograms[key].size > 1000
        end
      end

      # Set a gauge value (for current state metrics)
      # @param name [String] Gauge name
      # @param value [Numeric] Current value
      # @param tags [Hash] Additional tags
      # @return [void]
      def set_gauge(name, value, tags = {})
        return unless enabled?

        key = build_metric_key(name, tags)
        @mutex.synchronize { @gauges[key] = value }
      end

      # Record HTTP request metrics
      # @param method [String] HTTP method
      # @param url [String] Request URL
      # @param status_code [Integer] Response status code
      # @param duration [Float] Request duration in seconds
      # @param error [Exception, nil] Error if request failed
      # @return [void]
      def record_http_request(method, url, status_code, duration, error = nil)
        return unless enabled?

        # Extract domain from URL for grouping
        domain = extract_domain(url)

        # Record basic counters
        increment_counter('http_requests_total', 1, {
                            method: method.to_s.upcase,
                            domain: domain,
                            status_code: status_code.to_s
                          })

        # Record duration histogram
        record_histogram('http_request_duration_seconds', duration, {
                           method: method.to_s.upcase,
                           domain: domain
                         })

        # Record error if present
        if error
          increment_counter('http_request_errors_total', 1, {
                              method: method.to_s.upcase,
                              domain: domain,
                              error_class: error.class.name
                            })
        end

        # Record status code categories
        status_category = categorize_status_code(status_code)
        increment_counter('http_requests_by_status_category', 1, {
                            category: status_category,
                            domain: domain
                          })
      end

      # Record database operation metrics
      # @param operation [String] Database operation (insert, select, etc.)
      # @param duration [Float] Operation duration in seconds
      # @param error [Exception, nil] Error if operation failed
      # @return [void]
      def record_database_operation(operation, duration, error = nil)
        return unless enabled?

        increment_counter('database_operations_total', 1, { operation: operation })
        record_histogram('database_operation_duration_seconds', duration, { operation: operation })

        return unless error

        increment_counter('database_operation_errors_total', 1, {
                            operation: operation,
                            error_class: error.class.name
                          })
      end

      # Record memory usage metrics
      # @return [void]
      def record_memory_usage
        return unless enabled?

        if defined?(GC)
          gc_stat = GC.stat
          set_gauge('memory_heap_live_slots', gc_stat[:heap_live_slots])
          set_gauge('memory_heap_free_slots', gc_stat[:heap_free_slots])
          set_gauge('memory_total_allocated_objects', gc_stat[:total_allocated_objects])
        end

        # Record process memory if available
        return unless File.exist?('/proc/self/status')

        memory_kb = File.read('/proc/self/status')[/VmRSS:\s*(\d+)/, 1]
        set_gauge('memory_rss_bytes', memory_kb.to_i * 1024) if memory_kb
      end

      # Get current metrics snapshot
      # @return [Hash] Current metrics data
      def snapshot
        @mutex.synchronize do
          {
            counters: @counters.dup,
            histograms: calculate_histogram_stats,
            gauges: @gauges.dup,
            uptime_seconds: Time.current - @start_time,
            collected_at: Time.current.iso8601
          }
        end
      end

      # Export metrics in Prometheus format
      # @return [String] Prometheus-formatted metrics
      def to_prometheus
        return '' unless enabled?

        lines = []
        snapshot_data = snapshot

        # Export counters
        snapshot_data[:counters].each do |key, value|
          metric_name, tags = parse_metric_key(key)
          lines << prometheus_line(metric_name, value, tags, 'counter')
        end

        # Export histogram summaries
        snapshot_data[:histograms].each do |key, stats|
          metric_name, tags = parse_metric_key(key)
          lines << prometheus_line("#{metric_name}_count", stats[:count], tags, 'counter')
          lines << prometheus_line("#{metric_name}_sum", stats[:sum], tags, 'counter')

          stats[:percentiles].each do |percentile, value|
            quantile_tags = tags.merge(quantile: percentile.to_s)
            lines << prometheus_line(metric_name, value, quantile_tags, 'summary')
          end
        end

        # Export gauges
        snapshot_data[:gauges].each do |key, value|
          metric_name, tags = parse_metric_key(key)
          lines << prometheus_line(metric_name, value, tags, 'gauge')
        end

        lines.join("\n")
      end

      # Reset all metrics (useful for testing)
      # @return [void]
      def reset!
        @mutex.synchronize do
          @counters.clear
          @histograms.clear
          @gauges.clear
          @start_time = Time.current
        end
      end

      private

        # Check if metrics collection is enabled
        # @return [Boolean] true if enabled
        def enabled?
          @configuration.metrics_collection_enabled?
        end

        # Build metric key with tags
        # @param name [String] Metric name
        # @param tags [Hash] Tags to include
        # @return [String] Metric key
        def build_metric_key(name, tags = {})
          return name if tags.empty?

          tag_string = tags.map { |k, v| "#{k}:#{v}" }.sort.join(',')
          "#{name}{#{tag_string}}"
        end

        # Parse metric key back to name and tags
        # @param key [String] Metric key
        # @return [Array] [metric_name, tags_hash]
        def parse_metric_key(key)
          if key.include?('{')
            name, tag_part = key.split('{', 2)
            tag_part = tag_part.chomp('}')
            tags = tag_part.split(',').to_h { |pair| pair.split(':', 2) }
            [name, tags]
          else
            [key, {}]
          end
        end

        # Extract domain from URL
        # @param url [String] URL to parse
        # @return [String] Domain or 'unknown'
        def extract_domain(url)
          URI.parse(url).host || 'unknown'
        rescue URI::InvalidURIError
          'unknown'
        end

        # Categorize HTTP status code
        # @param status_code [Integer] HTTP status code
        # @return [String] Status category
        def categorize_status_code(status_code)
          case status_code.to_i
          when 200..299 then '2xx'
          when 300..399 then '3xx'
          when 400..499 then '4xx'
          when 500..599 then '5xx'
          else 'unknown'
          end
        end

        # Calculate histogram statistics
        # @return [Hash] Histogram statistics
        def calculate_histogram_stats
          @histograms.transform_values do |values|
            next { count: 0, sum: 0, percentiles: {} } if values.empty?

            sorted = values.sort
            count = values.size
            sum = values.sum

            {
              count: count,
              sum: sum,
              percentiles: {
                0.5 => percentile(sorted, 0.5),
                0.9 => percentile(sorted, 0.9),
                0.95 => percentile(sorted, 0.95),
                0.99 => percentile(sorted, 0.99)
              }
            }
          end
        end

        # Calculate percentile from sorted array
        # @param sorted_values [Array] Sorted numeric values
        # @param percentile [Float] Percentile (0.0 to 1.0)
        # @return [Float] Percentile value
        def percentile(sorted_values, percentile)
          return 0 if sorted_values.empty?
          return sorted_values.first if sorted_values.length == 1

          # Use linear interpolation for more accurate percentiles
          index = percentile * (sorted_values.length - 1)
          lower_index = index.floor
          upper_index = index.ceil

          if lower_index == upper_index
            sorted_values[lower_index]
          else
            # Linear interpolation between the two values
            lower_value = sorted_values[lower_index]
            upper_value = sorted_values[upper_index]
            weight = index - lower_index
            lower_value + (weight * (upper_value - lower_value))
          end
        end

        # Format metric line for Prometheus
        # @param name [String] Metric name
        # @param value [Numeric] Metric value
        # @param tags [Hash] Metric tags
        # @param type [String] Metric type
        # @return [String] Prometheus line
        def prometheus_line(name, value, tags, _type)
          if tags.empty?
            "#{name} #{value}"
          else
            tag_string = tags.map { |k, v| "#{k}=\"#{v}\"" }.join(',')
            "#{name}{#{tag_string}} #{value}"
          end
        end
    end
  end
end

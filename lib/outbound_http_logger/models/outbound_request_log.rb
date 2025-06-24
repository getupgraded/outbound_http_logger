# frozen_string_literal: true

require 'active_record'
require 'set'
require 'rack'
require_relative 'base_request_log'

module OutboundHttpLogger
  module Models
    class OutboundRequestLog < BaseRequestLog
      self.table_name = 'outbound_request_logs'

      # Disable updated_at for append-only logging - only use created_at
      def self.timestamp_attributes_for_update
        []
      end

      def self.timestamp_attributes_for_create
        ['created_at']
      end

      # Include database adapters based on connection type
      def self.inherited(subclass)
        super
        setup_database_adapters(subclass)
      end

      # Setup adapters when the class is first loaded
      def self.setup_database_adapters(klass = self)
        return unless defined?(ActiveRecord) && klass.connection

        case klass.connection.adapter_name
        when 'PostgreSQL'
          klass.include OutboundHttpLogger::DatabaseAdapters::PostgresqlAdapter
        when 'SQLite'
          klass.include OutboundHttpLogger::DatabaseAdapters::SqliteAdapter
        end
      rescue StandardError
        # Ignore connection errors during class loading
      end

      # Call setup when the class is loaded
      setup_database_adapters

      # Scopes
      scope :recent, -> { order(created_at: :desc) }
      scope :with_status, ->(status) { where(status_code: status) }
      scope :with_method, ->(method) { where(http_method: method.to_s.upcase) }
      scope :for_loggable, ->(loggable) { where(loggable: loggable) }
      scope :with_error, -> { where('status_code >= ?', 400) }
      scope :successful, -> { where(status_code: 200..399) }
      scope :failed, -> { where('status_code >= 400') }
      scope :slow, ->(threshold_ms = 1000) { where('duration_ms > ?', threshold_ms) }

      # JSON columns are automatically serialized in Rails 8.0+
      # No explicit serialization needed

      # Class methods for logging
      class << self
        # Log an outbound HTTP request with failsafe error handling
        def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0, options = {})
          return unless OutboundHttpLogger.enabled?
          return unless OutboundHttpLogger.configuration.should_log_url?(url)

          # Check content type filtering
          content_type = response_data[:headers]&.[]('content-type') ||
                         response_data[:headers]&.[]('Content-Type')
          return unless OutboundHttpLogger.configuration.should_log_content_type?(content_type)

          duration_ms = (duration_seconds * 1000).round(2)

          # Get thread-local metadata and loggable
          thread_metadata = Thread.current[:outbound_http_logger_metadata] || {}
          thread_loggable = Thread.current[:outbound_http_logger_loggable]

          # Merge metadata
          merged_metadata = thread_metadata.merge(request_data[:metadata] || {}).merge(options[:metadata] || {})

          # Prepare log data
          log_data = {
            http_method: method.to_s.upcase,
            url: url,
            status_code: response_data[:status_code] || 0,
            request_headers: OutboundHttpLogger.configuration.filter_headers(request_data[:headers] || {}),
            request_body: OutboundHttpLogger.configuration.filter_body(request_data[:body]),
            response_headers: OutboundHttpLogger.configuration.filter_headers(response_data[:headers] || {}),
            response_body: OutboundHttpLogger.configuration.filter_body(response_data[:body]),
            duration_seconds: duration_seconds,
            duration_ms: duration_ms,
            loggable: request_data[:loggable] || thread_loggable,
            metadata: merged_metadata
          }



          # Apply database-specific optimizations
          log_data = optimize_for_database(log_data)

          create!(log_data)
        rescue => e
          # Failsafe: Never let logging errors break the HTTP request
          logger = OutboundHttpLogger.configuration.get_logger
          logger&.error("OutboundHttpLogger: Failed to log request: #{e.class}: #{e.message}")
          nil
        end

        # Search logs by various criteria
        def search(params = {})
          scope = all

          # General search
          if params[:q].present?
            q     = "%#{params[:q].downcase}%"
            scope = scope.where(
              'LOWER(url) LIKE ? OR LOWER(request_body) LIKE ? OR LOWER(response_body) LIKE ?',
              q,
              q,
              q
            )
          end

          # Filter by status
          if params[:status].present?
            statuses = Array(params[:status]).map(&:to_i)
            scope    = scope.where(status_code: statuses)
          end

          # Filter by HTTP method
          if params[:method].present?
            methods = Array(params[:method]).map(&:upcase)
            scope   = scope.where(http_method: methods)
          end

          # Filter by loggable
          if params[:loggable_id].present? && params[:loggable_type].present?
            scope = scope.where(
              loggable_id: params[:loggable_id],
              loggable_type: params[:loggable_type]
            )
          end

          # Filter by date range
          if params[:start_date].present?
            start_date = Time.zone.parse(params[:start_date]).beginning_of_day rescue nil
            scope      = scope.where('created_at >= ?', start_date) if start_date
          end

          if params[:end_date].present?
            end_date = Time.zone.parse(params[:end_date]).end_of_day rescue nil
            scope    = scope.where('created_at <= ?', end_date) if end_date
          end

          # Filter slow requests
          if params[:slow_threshold].present?
            scope = scope.slow(params[:slow_threshold].to_i)
          end

          scope
        end

        # Clean up old logs
        def cleanup(older_than_days = 90)
          where('created_at < ?', older_than_days.days.ago).delete_all
        end

        private

          # Apply database-specific optimizations to log data
          def optimize_for_database(log_data)
            case connection.adapter_name
            when 'PostgreSQL'
              optimize_for_postgresql(log_data)
            when 'SQLite'
              optimize_for_sqlite(log_data)
            else
              log_data
            end
          rescue StandardError
            # Fallback to original data if optimization fails
            log_data
          end

          # PostgreSQL optimizations: convert JSON strings to objects for JSONB storage
          def optimize_for_postgresql(log_data)
            %i[request_body response_body].each do |field|
              next unless log_data[field].is_a?(String) && log_data[field].present?

              begin
                log_data[field] = JSON.parse(log_data[field])
              rescue JSON::ParserError
                # Keep as string if not valid JSON
              end
            end
            # Headers and metadata are already objects, don't convert them
            log_data
          end

          # SQLite optimizations: ensure JSON fields are properly serialized
          def optimize_for_sqlite(log_data)
            # For SQLite, Rails will automatically handle JSON serialization
            # We don't need to manually convert to JSON strings as that can
            # interfere with the filtering that's already been applied
            # Just ensure the data is in the right format
            log_data
          end
      end

      # Instance methods

      # Get a formatted string of the request
      def formatted_request
        "#{http_method} #{url}\n#{formatted_headers(request_headers)}\n\n#{formatted_body(request_body)}"
      end

      # Get a formatted string of the response
      def formatted_response
        "HTTP #{status_code} #{status_text}\n#{formatted_headers(response_headers)}\n\n#{formatted_body(response_body)}"
      end

      # Check if the request was successful
      def success?
        status_code.between?(200, 399)
      end

      # Check if the request failed
      def failure?
        !success?
      end

      # Check if the request was slow
      def slow?(threshold_ms = 1000)
        duration_ms > threshold_ms
      end

      # Get the duration in a human-readable format
      def formatted_duration
        if duration_ms < 1000
          "#{duration_ms.round(2)}ms"
        else
          "#{duration_seconds.round(2)}s"
        end
      end

      # Get status text
      def status_text
        Rack::Utils::HTTP_STATUS_CODES[status_code] || status_code.to_s
      end

      private

        # Format headers for display
        def formatted_headers(headers)
          return '' unless headers.is_a?(Hash)

          headers.map { |k, v| "#{k}: #{v}" }.join("\n")
        end

        # Format body for display
        def formatted_body(body)
          return '' if body.blank?

          if body.is_a?(Hash) || body.is_a?(Array)
            JSON.pretty_generate(body)
          else
            body.to_s
          end
        end
    end
  end
end

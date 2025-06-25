# frozen_string_literal: true

require 'active_record'
require 'set'
require 'rack'

module OutboundHttpLogger
  module Models
    class OutboundRequestLog < ActiveRecord::Base
      self.table_name = 'outbound_request_logs'

      # Associations
      belongs_to :loggable, polymorphic: true, optional: true

      # Validations
      validates :http_method, presence: true
      validates :url, presence: true
      validates :status_code, presence: true, numericality: { only_integer: true }

      # Disable updated_at for append-only logging - only use created_at
      def self.timestamp_attributes_for_update
        []
      end

      def self.timestamp_attributes_for_create
        ['created_at']
      end

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

      # Check if we're using JSONB (PostgreSQL) or regular JSON
      # Memoized for performance since this is called on every log entry
      def self.using_jsonb?
        # Use instance variable for memoization that can be reset
        @using_jsonb = connection.adapter_name == 'PostgreSQL' &&
                       columns_hash['response_body']&.sql_type == 'jsonb' if @using_jsonb.nil?
        @using_jsonb
      end

      # Reset memoized database adapter information (for testing)
      def self.reset_adapter_cache!
        @using_jsonb = nil
      end

      # Class methods for logging
      class << self
        # Log an outbound HTTP request with failsafe error handling
        def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0, options = {})
          config = OutboundHttpLogger.configuration
          return nil unless config.enabled?
          return nil unless config.should_log_url?(url)

          # Check content type filtering
          content_type = response_data[:headers]&.[]('content-type') ||
                         response_data[:headers]&.[]('Content-Type')
          return nil unless config.should_log_content_type?(content_type)

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
            scope = apply_text_search(scope, q, params[:q])
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

        # Statistics methods
        def success_rate
          total = count
          return 0.0 if total.zero?

          successful_count = successful.count
          (successful_count.to_f / total * 100).round(2)
        end

        def average_duration
          average(:duration_ms)&.round(2) || 0.0
        end

        def total_requests
          count
        end



        # Database-specific text search
        def apply_text_search(scope, q, original_query)
          adapter_name = connection.adapter_name.downcase
          case adapter_name
          when 'postgresql'
            # Use PostgreSQL-specific text search with ILIKE for case-insensitive search
            scope.where(
              'LOWER(url) LIKE ? OR request_body ILIKE ? OR response_body ILIKE ?',
              q, "%#{original_query}%", "%#{original_query}%"
            )
          else
            # Default implementation for SQLite and other databases
            scope.where(
              'LOWER(url) LIKE ? OR LOWER(request_body) LIKE ? OR LOWER(response_body) LIKE ?',
              q, q, q
            )
          end
        rescue ActiveRecord::ConnectionNotEstablished
          # Fallback if connection is not established
          scope.where('LOWER(url) LIKE ?', q)
        end

        # JSON search methods
        def with_response_containing(key, value)
          # Basic string search fallback - handle JSON stored as strings
          # Search for both key and value being present in the JSON
          where('response_body LIKE ? AND response_body LIKE ?', "%#{key}%", "%#{value}%")
        end

        def with_request_containing(key, value)
          # Basic string search fallback - handle JSON stored as strings
          # Search for both key and value being present in the JSON
          where('request_body LIKE ? AND request_body LIKE ?', "%#{key}%", "%#{value}%")
        end

        def with_metadata_containing(key, value)
          # Basic string search fallback
          where('metadata LIKE ?', "%\"#{key}\":\"#{value}\"%")
        end

        def with_response_header(header_name, header_value = nil)
          if header_value
            where('response_headers LIKE ?', "%\"#{header_name}\":\"#{header_value}\"%")
          else
            where('response_headers LIKE ?', "%\"#{header_name}\":%")
          end
        end

        def with_request_header(header_name, header_value = nil)
          if header_value
            where('request_headers LIKE ?', "%\"#{header_name}\":\"#{header_value}\"%")
          else
            where('request_headers LIKE ?', "%\"#{header_name}\":%")
          end
        end

        private

          # Apply database-specific optimizations to log data
          def optimize_for_database(log_data)
            if using_jsonb?
              optimize_for_jsonb(log_data)
            else
              optimize_for_json_strings(log_data)
            end
          rescue StandardError
            # Fallback to original data if optimization fails
            log_data
          end

          # JSONB optimizations: ensure JSON fields are stored as objects for JSONB
          def optimize_for_jsonb(log_data)
            # For PostgreSQL with JSONB columns, we want to store actual objects, not strings
            # This allows for native JSON indexing, querying, and performance benefits
            %i[request_headers response_headers request_body response_body metadata].each do |field|
              next unless log_data[field]

              # If it's already an object (Hash/Array), keep it as-is for JSONB
              next unless log_data[field].is_a?(String)

              # Try to parse JSON strings into objects for JSONB storage
              begin
                log_data[field] = JSON.parse(log_data[field])
              rescue JSON::ParserError
                # Keep as string if not valid JSON
              end
            end
            log_data
          end

          # JSON string optimizations: ensure JSON fields are properly serialized
          def optimize_for_json_strings(log_data)
            # For SQLite, ensure JSON fields are properly serialized
            %i[request_headers request_body response_headers response_body metadata].each do |field|
              log_data[field] = serialize_json_field(log_data[field]) if log_data[field]
            end
            log_data
          end

          # Serialize JSON field for SQLite
          def serialize_json_field(value)
            return nil if value.nil?
            return value if value.is_a?(String)

            begin
              value.to_json
            rescue StandardError
              value.to_s
            end
          end
      end

      # Instance methods

      # Override request_headers to automatically parse JSON strings
      def request_headers
        parsed_request_headers
      end

      # Override response_headers to automatically parse JSON strings
      def response_headers
        parsed_response_headers
      end

      # Override metadata to automatically parse JSON strings
      def metadata
        parsed_metadata
      end

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

      # Additional instance methods from base class
      def successful?
        (200..299).include?(status_code)
      end

      def failed?
        !successful?
      end

      def parsed_request_headers
        raw_headers = read_attribute(:request_headers)
        return {} unless raw_headers.present?

        case raw_headers
        when String
          JSON.parse(raw_headers)
        when Hash
          raw_headers
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end

      def parsed_response_headers
        raw_headers = read_attribute(:response_headers)
        return {} unless raw_headers.present?

        case raw_headers
        when String
          JSON.parse(raw_headers)
        when Hash
          raw_headers
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end

      def parsed_metadata
        raw_metadata = read_attribute(:metadata)
        return {} unless raw_metadata.present?

        case raw_metadata
        when String
          JSON.parse(raw_metadata)
        when Hash
          raw_metadata
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end

      def duration_in_seconds
        duration_seconds || (duration_ms ? duration_ms / 1000.0 : 0.0)
      end

      def to_hash
        {
          id: id,
          http_method: http_method,
          url: url,
          status_code: status_code,
          request_headers: parsed_request_headers,
          response_headers: parsed_response_headers,
          duration_ms: duration_ms,
          duration_seconds: duration_seconds,
          successful: successful?,
          loggable_type: loggable_type,
          loggable_id: loggable_id,
          metadata: parsed_metadata,
          created_at: created_at,
          updated_at: updated_at
        }
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

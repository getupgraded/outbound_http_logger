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
        def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0)
          return unless OutboundHttpLogger.enabled?
          return unless OutboundHttpLogger.configuration.should_log_url?(url)

          # Check content type filtering
          content_type = response_data[:headers]&.[]('content-type') ||
                         response_data[:headers]&.[]('Content-Type')
          return unless OutboundHttpLogger.configuration.should_log_content_type?(content_type)

          duration_ms = (duration_seconds * 1000).round(2)

          create!(
            http_method: method.to_s.upcase,
            url: url,
            status_code: response_data[:status_code] || 0,
            request_headers: OutboundHttpLogger.configuration.filter_headers(request_data[:headers] || {}),
            request_body: OutboundHttpLogger.configuration.filter_body(request_data[:body]),
            response_headers: OutboundHttpLogger.configuration.filter_headers(response_data[:headers] || {}),
            response_body: OutboundHttpLogger.configuration.filter_body(response_data[:body]),
            duration_seconds: duration_seconds,
            duration_ms: duration_ms,
            loggable: request_data[:loggable],
            metadata: request_data[:metadata] || {}
          )
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

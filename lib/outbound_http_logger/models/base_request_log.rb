# frozen_string_literal: true

require 'active_record'
require 'set'
require 'rack'

module OutboundHttpLogger
  module Models
    class BaseRequestLog < ActiveRecord::Base
      self.abstract_class = true

      # Associations
      belongs_to :loggable, polymorphic: true, optional: true

      # Validations
      validates :http_method, presence: true
      validates :url, presence: true
      validates :status_code, presence: true, numericality: { only_integer: true }

      # Scopes for common queries
      scope :recent, -> { order(created_at: :desc) }
      scope :with_status, ->(status) { where(status_code: status) }
      scope :with_method, ->(method) { where(http_method: method.to_s.upcase) }
      scope :successful, -> { where(status_code: 200..299) }
      scope :failed, -> { where.not(status_code: 200..299) }
      scope :slow, ->(threshold_ms = 1000) { where('duration_ms > ?', threshold_ms) }
      scope :for_loggable, ->(loggable) { where(loggable: loggable) }

      # Search scope with database-specific implementations
      scope :search, lambda { |params|
        scope = all
        return scope unless params.is_a?(Hash)

        # Text search
        if params[:q].present?
          q = "%#{params[:q].downcase}%"
          scope = apply_text_search(scope, q, params[:q])
        end

        # Status filter
        scope = scope.with_status(params[:status]) if params[:status].present?

        # Method filter
        scope = scope.with_method(params[:method]) if params[:method].present?

        # Date range
        if params[:start_date].present?
          scope = scope.where('created_at >= ?', params[:start_date])
        end

        if params[:end_date].present?
          scope = scope.where('created_at <= ?', params[:end_date])
        end

        # Duration filter
        if params[:min_duration_ms].present?
          scope = scope.where('duration_ms >= ?', params[:min_duration_ms])
        end

        if params[:max_duration_ms].present?
          scope = scope.where('duration_ms <= ?', params[:max_duration_ms])
        end

        # Loggable filter
        if params[:loggable_type].present?
          scope = scope.where(loggable_type: params[:loggable_type])
        end

        if params[:loggable_id].present?
          scope = scope.where(loggable_id: params[:loggable_id])
        end

        scope
      }

      # Class methods
      class << self
        # Cleanup old logs
        def cleanup(older_than_days = 30)
          where('created_at < ?', older_than_days.days.ago).delete_all
        end

        # Statistics
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

        # Database-specific text search (to be implemented by adapters)
        def apply_text_search(scope, q, original_query)
          # Default implementation for unsupported databases
          scope.where('LOWER(url) LIKE ?', q)
        end

        # Fallback methods for databases without adapter-specific implementations
        def with_response_containing(key, value)
          # Basic string search fallback
          where('response_body LIKE ?', "%\"#{key}\":\"#{value}\"%")
        end

        def with_request_containing(key, value)
          # Basic string search fallback
          where('request_body LIKE ?', "%\"#{key}\":\"#{value}\"%")
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
      end

      # Instance methods
      def successful?
        (200..299).include?(status_code)
      end

      def failed?
        !successful?
      end

      def slow?(threshold_ms = 1000)
        duration_ms && duration_ms > threshold_ms
      end

      def parsed_request_headers
        return {} unless request_headers.present?

        case request_headers
        when String
          JSON.parse(request_headers)
        when Hash
          request_headers
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end

      def parsed_response_headers
        return {} unless response_headers.present?

        case response_headers
        when String
          JSON.parse(response_headers)
        when Hash
          response_headers
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end

      def parsed_metadata
        return {} unless metadata.present?

        case metadata
        when String
          JSON.parse(metadata)
        when Hash
          metadata
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end

      def duration_in_seconds
        duration_seconds || (duration_ms ? duration_ms / 1000.0 : 0.0)
      end

      def formatted_duration
        if duration_ms
          if duration_ms < 1000
            "#{duration_ms.round(2)}ms"
          else
            "#{(duration_ms / 1000.0).round(2)}s"
          end
        else
          "0ms"
        end
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
    end
  end
end

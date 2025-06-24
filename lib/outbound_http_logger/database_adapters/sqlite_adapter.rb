# frozen_string_literal: true

require 'active_record'

module OutboundHttpLogger
  module DatabaseAdapters
    module SqliteAdapter
      extend ActiveSupport::Concern

      included do
        # SQLite-specific scopes and methods
        class << self
            def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0, options = {})
              log_data = build_log_data(method, url, request_data, response_data, duration_seconds, options)
              return nil unless log_data

              create!(log_data)
            end

            # SQLite-specific text search
            def apply_text_search(scope, q, original_query)
              scope.where(
                'LOWER(url) LIKE ? OR LOWER(request_body) LIKE ? OR LOWER(response_body) LIKE ?',
                q, q, q
              )
            end

            # SQLite-specific JSON scopes
            def with_response_containing(key, value)
              where("JSON_EXTRACT(response_body, ?) = ?", "$.#{key}", value.to_s)
            end

            def with_request_containing(key, value)
              where("JSON_EXTRACT(request_body, ?) = ?", "$.#{key}", value.to_s)
            end

            def with_metadata_containing(key, value)
              where("JSON_EXTRACT(metadata, ?) = ?", "$.#{key}", value.to_s)
            end

            # SQLite-specific header queries
            def with_response_header(header_name, header_value = nil)
              if header_value
                where("JSON_EXTRACT(response_headers, ?) = ?", "$.#{header_name}", header_value.to_s)
              else
                where("JSON_EXTRACT(response_headers, ?) IS NOT NULL", "$.#{header_name}")
              end
            end

            def with_request_header(header_name, header_value = nil)
              if header_value
                where("JSON_EXTRACT(request_headers, ?) = ?", "$.#{header_name}", header_value.to_s)
              else
                where("JSON_EXTRACT(request_headers, ?) IS NOT NULL", "$.#{header_name}")
              end
            end

            private

              def build_log_data(method, url, request_data, response_data, duration_seconds, options)
                return nil unless OutboundHttpLogger.enabled?
                return nil unless OutboundHttpLogger.configuration.should_log_url?(url)

                # Check content type filtering
                content_type = response_data[:headers]&.[]('content-type') ||
                               response_data[:headers]&.[]('Content-Type')
                return nil unless OutboundHttpLogger.configuration.should_log_content_type?(content_type)

                duration_ms = (duration_seconds * 1000).round(2)

                # Get thread-local metadata and loggable
                thread_metadata = Thread.current[:outbound_http_logger_metadata] || {}
                thread_loggable = Thread.current[:outbound_http_logger_loggable]

                # Merge metadata
                merged_metadata = thread_metadata.merge(request_data[:metadata] || {}).merge(options[:metadata] || {})

                # For SQLite, ensure JSON fields are properly serialized
                {
                  http_method: method.to_s.upcase,
                  url: url,
                  status_code: response_data[:status_code] || 0,
                  request_headers: serialize_json_field(OutboundHttpLogger.configuration.filter_headers(request_data[:headers] || {})),
                  request_body: serialize_json_field(OutboundHttpLogger.configuration.filter_body(request_data[:body])),
                  response_headers: serialize_json_field(OutboundHttpLogger.configuration.filter_headers(response_data[:headers] || {})),
                  response_body: serialize_json_field(OutboundHttpLogger.configuration.filter_body(response_data[:body])),
                  duration_seconds: duration_seconds,
                  duration_ms: duration_ms,
                  loggable: request_data[:loggable] || thread_loggable,
                  metadata: serialize_json_field(merged_metadata)
                }
              end

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

        def build_create_table_sql
          <<~SQL
            CREATE TABLE IF NOT EXISTS outbound_request_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              http_method VARCHAR(10) NOT NULL,
              url TEXT NOT NULL,
              status_code INTEGER NOT NULL,
              request_headers TEXT DEFAULT '{}',
              request_body TEXT,
              response_headers TEXT DEFAULT '{}',
              response_body TEXT,
              duration_seconds REAL,
              duration_ms REAL,
              loggable_type VARCHAR(255),
              loggable_id INTEGER,
              metadata TEXT DEFAULT '{}',
              created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
          SQL
        end

        def build_indexes_sql
          [
            # Essential indexes for append-only logging (minimal set)
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_created_at ON outbound_request_logs (created_at)",
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_loggable ON outbound_request_logs (loggable_type, loggable_id)",

            # SQLite text search index
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_url ON outbound_request_logs (url)"
          ]
        end
      end
    end
  end
end

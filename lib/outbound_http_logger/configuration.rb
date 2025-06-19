# frozen_string_literal: true

module OutboundHttpLogger
  class Configuration
    attr_accessor :enabled,
                  :excluded_urls,
                  :excluded_content_types,
                  :sensitive_headers,
                  :sensitive_body_keys,
                  :max_body_size,
                  :debug_logging,
                  :logger

    def initialize
      @enabled                = false
      @excluded_urls          = [
        %r{https://o\d+\.ingest\..*\.sentry\.io},  # Sentry URLs
        %r{/health},                               # Health check endpoints
        %r{/ping}                                  # Ping endpoints
      ]
      @excluded_content_types = [
        'text/html',
        'text/css',
        'text/javascript',
        'application/javascript',
        'image/',
        'video/',
        'audio/',
        'font/'
      ]
      @sensitive_headers = [
        'authorization',
        'cookie',
        'set-cookie',
        'x-api-key',
        'x-auth-token',
        'x-access-token',
        'bearer'
      ]
      @sensitive_body_keys = [
        'password',
        'secret',
        'token',
        'key',
        'auth',
        'credential',
        'private'
      ]
      @max_body_size          = 10_000 # 10KB
      @debug_logging          = false
      @logger                 = nil
    end

    def enabled?
      @enabled == true
    end

    def should_log_url?(url)
      return false unless enabled?
      return false if url.nil? || url.empty?

      @excluded_urls.none? { |pattern| pattern.match?(url) }
    end

    def should_log_content_type?(content_type)
      return true if content_type.nil? || content_type.empty?

      # Handle both String and Array content types (Rails 7 compatibility)
      content_type_str = case content_type
                         when Array
                           content_type.first.to_s
                         when String
                           content_type
                         else
                           content_type.to_s
                         end

      return true if content_type_str.empty?

      @excluded_content_types.none? { |excluded| content_type_str.start_with?(excluded) }
    end

    def get_logger
      @logger || (defined?(Rails) ? Rails.logger : nil)
    end

    # Filter sensitive headers
    def filter_headers(headers)
      return {} if headers.nil? || headers.empty?

      filtered = {}
      headers.each do |key, value|
        key_lower = key.to_s.downcase
        if @sensitive_headers.any? { |sensitive| key_lower.include?(sensitive) }
          filtered[key] = '[FILTERED]'
        else
          filtered[key] = value
        end
      end
      filtered
    end

    # Filter sensitive data from request/response bodies
    def filter_body(body)
      return nil if body.nil? || body.empty?
      return body if body.size > @max_body_size

      # If it's JSON, try to parse and filter sensitive keys
      if body.is_a?(String) && (body.strip.start_with?('{') || body.strip.start_with?('['))
        begin
          parsed   = JSON.parse(body)
          filtered = filter_json_data(parsed)
          return filtered.to_json
        rescue JSON::ParserError
          # If parsing fails, return the original body (truncated if needed)
        end
      end

      body
    end

    private

      def filter_json_data(data)
        case data
        when Hash
          filtered = {}
          data.each do |key, value|
            key_str = key.to_s.downcase
            if @sensitive_body_keys.any? { |sensitive| key_str.include?(sensitive) }
              filtered[key] = '[FILTERED]'
            else
              filtered[key] = filter_json_data(value)
            end
          end
          filtered
        when Array
          data.map { |item| filter_json_data(item) }
        else
          data
        end
      end
  end
end

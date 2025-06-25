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
                  :logger,
                  :secondary_database_url,
                  :secondary_database_adapter

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

      # Secondary database configuration
      @secondary_database_url = nil
      @secondary_database_adapter = :sqlite
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

    # Secondary database configuration
    def configure_secondary_database(database_url, adapter: :sqlite)
      @secondary_database_url = database_url
      @secondary_database_adapter = adapter.to_sym
    end

    def secondary_database_configured?
      @secondary_database_url.present?
    end

    def clear_secondary_database
      @secondary_database_url = nil
      @secondary_database_adapter = :sqlite
    end

    # Filter sensitive data from headers
    def filter_headers(headers)
      return {} unless headers.is_a?(Hash)

      filtered = headers.dup
      @sensitive_headers.each do |sensitive_header|
        filtered.each_key do |key|
          if key.to_s.downcase == sensitive_header.downcase
            filtered[key] = '[FILTERED]'
          end
        end
      end
      filtered
    end

    # Filter sensitive data from request/response body
    def filter_body(body)
      return nil if body.nil?
      return body unless body.is_a?(String)
      return body if body.length > @max_body_size

      # Try to parse as JSON and filter sensitive keys
      begin
        parsed = JSON.parse(body)
        if parsed.is_a?(Hash)
          filtered = filter_hash_keys(parsed)
          return filtered.to_json
        end
      rescue JSON::ParserError
        # Not JSON, return as-is (truncated if needed)
      end

      body
    end

    private

      def filter_hash_keys(hash)
        return hash unless hash.is_a?(Hash)

        filtered = hash.dup
        @sensitive_body_keys.each do |sensitive_key|
          filtered.each_key do |key|
            if key.to_s.downcase.include?(sensitive_key.downcase)
              filtered[key] = '[FILTERED]'
            end
          end
        end

        # Recursively filter nested hashes
        filtered.each do |key, value|
          filtered[key] = filter_hash_keys(value) if value.is_a?(Hash)
        end

        filtered
      end

    public

    # Create a backup of the current configuration state
    def backup
      {
        enabled: @enabled,
        excluded_urls: @excluded_urls.dup,
        excluded_content_types: @excluded_content_types.dup,
        sensitive_headers: @sensitive_headers.dup,
        sensitive_body_keys: @sensitive_body_keys.dup,
        max_body_size: @max_body_size,
        debug_logging: @debug_logging,
        logger: @logger,
        secondary_database_url: @secondary_database_url,
        secondary_database_adapter: @secondary_database_adapter
      }
    end

    # Restore configuration from a backup
    def restore(backup)
      @enabled = backup[:enabled]
      @excluded_urls = backup[:excluded_urls]
      @excluded_content_types = backup[:excluded_content_types]
      @sensitive_headers = backup[:sensitive_headers]
      @sensitive_body_keys = backup[:sensitive_body_keys]
      @max_body_size = backup[:max_body_size]
      @debug_logging = backup[:debug_logging]
      @logger = backup[:logger]
      @secondary_database_url = backup[:secondary_database_url]
      @secondary_database_adapter = backup[:secondary_database_adapter]
    end
  end
end

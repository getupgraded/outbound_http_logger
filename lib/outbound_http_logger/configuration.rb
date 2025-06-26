# frozen_string_literal: true

require 'logger'
require 'stringio'

module OutboundHTTPLogger
  class Configuration
    # Default configuration constants
    DEFAULT_MAX_BODY_SIZE = 10_000 # 10KB - Maximum size for request/response bodies
    DEFAULT_MAX_RECURSION_DEPTH = 3 # Maximum allowed recursion depth before raising error
    DEFAULT_CONNECTION_POOL_SIZE = 5 # Default database connection pool size
    DEFAULT_CONNECTION_TIMEOUT = 5000 # Default database connection timeout in milliseconds
    DEFAULT_LOG_FETCH_LIMIT = 1000 # Default limit for fetching logs to prevent memory issues

    attr_accessor :enabled,
                  :excluded_urls,
                  :excluded_content_types,
                  :sensitive_headers,
                  :sensitive_body_keys,
                  :max_body_size,
                  :debug_logging,
                  :logger,
                  :secondary_database_url,
                  :secondary_database_adapter,
                  :max_recursion_depth,
                  :strict_recursion_detection,
                  :observability_enabled,
                  :structured_logging_enabled,
                  :structured_logging_format,
                  :structured_logging_level,
                  :metrics_collection_enabled,
                  :debug_tools_enabled,
                  :performance_logging_threshold

    def initialize
      @mutex                  = Mutex.new
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
      @sensitive_headers = %w[
        authorization
        cookie
        set-cookie
        x-api-key
        x-auth-token
        x-access-token
        bearer
      ]
      @sensitive_body_keys = %w[
        password
        secret
        token
        key
        auth
        credential
        private
      ]
      @max_body_size          = DEFAULT_MAX_BODY_SIZE
      @debug_logging          = false
      @logger                 = nil

      # Secondary database configuration
      @secondary_database_url = nil
      @secondary_database_adapter = :sqlite

      # Recursion detection configuration
      @max_recursion_depth = DEFAULT_MAX_RECURSION_DEPTH
      @strict_recursion_detection = false # Whether to raise errors on recursion detection

      # Observability configuration
      @observability_enabled = false
      @structured_logging_enabled = false
      @structured_logging_format = :json # :json or :key_value
      @structured_logging_level = :info # :debug, :info, :warn, :error, :fatal
      @metrics_collection_enabled = false
      @debug_tools_enabled = false
      @performance_logging_threshold = 1.0 # Log operations slower than 1 second
    end

    # Check if logging is enabled
    # @return [Boolean] true if logging is enabled
    def enabled?
      @enabled == true
    end

    # Determine if a URL should be logged based on configuration
    # @param url [String] The URL to check
    # @return [Boolean] true if the URL should be logged
    def should_log_url?(url)
      return false unless logging_enabled_for_url?
      return false unless valid_url?(url)

      !url_excluded?(url)
    end

    # Check if logging is enabled for URL filtering
    # @return [Boolean] true if logging is enabled
    def logging_enabled_for_url?
      enabled?
    end

    # Validate that URL is present and not blank
    # @param url [String] The URL to validate
    # @return [Boolean] true if URL is valid
    def valid_url?(url)
      url.present?
    end

    # Check if URL matches any exclusion patterns
    # @param url [String] The URL to check against exclusion patterns
    # @return [Boolean] true if URL should be excluded
    def url_excluded?(url)
      @excluded_urls.any? { |pattern| pattern.match?(url) }
    end

    # Determine if a content type should be logged
    # @param content_type [String] The content type to check
    # @return [Boolean] true if the content type should be logged
    def should_log_content_type?(content_type)
      return true if content_type.blank?

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
      return @logger if @logger

      # Try Rails.logger if Rails is available and has a working logger
      return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      # Fallback to a default logger
      @get_logger ||= create_fallback_logger
    end

    private

      def create_fallback_logger
        # In test environments, use a quiet logger unless debugging
        if test_environment?
          ::Logger.new(StringIO.new)
        else
          # In non-test environments, log to stderr for visibility
          ::Logger.new($stderr)
        end
      end

      def test_environment?
        # Check various ways to detect test environment
        (defined?(Rails) && Rails.env&.test?) ||
          ENV['RACK_ENV'] == 'test' ||
          ENV['RAILS_ENV'] == 'test' ||
          ENV['RUBY_ENV'] == 'test' ||
          # Check if we're running under common test frameworks
          (defined?(Minitest) && $PROGRAM_NAME.include?('test')) ||
          (defined?(RSpec) && $PROGRAM_NAME.include?('rspec')) ||
          # Check if test gems are loaded
          defined?(Minitest::Test) ||
          defined?(RSpec::Core) ||
          # Check command line patterns
          ($PROGRAM_NAME.include?('rake') && ARGV.include?('test'))
      end

    public

    # Observability configuration methods

    # Check if observability features are enabled
    # @return [Boolean] true if observability is enabled
    def observability_enabled?
      @observability_enabled == true
    end

    # Check if structured logging is enabled
    # @return [Boolean] true if structured logging is enabled
    def structured_logging_enabled?
      @structured_logging_enabled == true
    end

    # Check if metrics collection is enabled
    # @return [Boolean] true if metrics collection is enabled
    def metrics_collection_enabled?
      @metrics_collection_enabled == true
    end

    # Check if debug tools are enabled
    # @return [Boolean] true if debug tools are enabled
    def debug_tools_enabled?
      @debug_tools_enabled == true
    end

    # Recursion detection and prevention
    def check_recursion_depth!(library_name)
      return unless @strict_recursion_detection

      depth_key = :"outbound_http_logger_depth_#{library_name}"
      current_depth = Thread.current[depth_key] || 0

      return unless current_depth >= @max_recursion_depth

      error_msg = "OutboundHTTPLogger: Infinite recursion detected in #{library_name} (depth: #{current_depth}). " \
                  'This usually indicates that the HTTP library is being used within the logging process itself. ' \
                  'Check your logger configuration and database connection settings.'

      # Log the error if possible (but don't use HTTP logging!)
      if get_logger && !Thread.current[:outbound_http_logger_logging_error]
        Thread.current[:outbound_http_logger_logging_error] = true
        begin
          get_logger.error(error_msg)
        ensure
          Thread.current[:outbound_http_logger_logging_error] = false
        end
      end

      raise OutboundHTTPLogger::InfiniteRecursionError, error_msg
    end

    def increment_recursion_depth(library_name)
      depth_key = :"outbound_http_logger_depth_#{library_name}"
      Thread.current[depth_key] = (Thread.current[depth_key] || 0) + 1
    end

    def decrement_recursion_depth(library_name)
      depth_key = :"outbound_http_logger_depth_#{library_name}"
      current_depth = Thread.current[depth_key] || 0
      new_depth = [current_depth - 1, 0].max

      # Set to nil when depth reaches 0 to indicate no active recursion tracking
      Thread.current[depth_key] = new_depth.zero? ? nil : new_depth
    end

    def current_recursion_depth(library_name)
      depth_key = :"outbound_http_logger_depth_#{library_name}"
      Thread.current[depth_key] || 0
    end

    def in_recursion?(library_name)
      current_recursion_depth(library_name).positive?
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
          filtered[key] = '[FILTERED]' if key.to_s.downcase == sensitive_header.downcase
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
            filtered[key] = '[FILTERED]' if key.to_s.downcase.include?(sensitive_key.downcase)
          end
        end

        # Recursively filter nested hashes
        filtered.each do |key, value|
          filtered[key] = filter_hash_keys(value) if value.is_a?(Hash)
        end

        filtered
      end

    public

    # Create a backup of the current configuration state (thread-safe)
    def backup
      @mutex.synchronize do
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
          secondary_database_adapter: @secondary_database_adapter,
          max_recursion_depth: @max_recursion_depth,
          strict_recursion_detection: @strict_recursion_detection,
          observability_enabled: @observability_enabled,
          structured_logging_enabled: @structured_logging_enabled,
          structured_logging_format: @structured_logging_format,
          structured_logging_level: @structured_logging_level,
          metrics_collection_enabled: @metrics_collection_enabled,
          debug_tools_enabled: @debug_tools_enabled,
          performance_logging_threshold: @performance_logging_threshold
        }
      end
    end

    # Restore configuration from a backup (thread-safe)
    def restore(backup)
      @mutex.synchronize do
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
        @max_recursion_depth = backup[:max_recursion_depth] if backup.key?(:max_recursion_depth)
        @strict_recursion_detection = backup[:strict_recursion_detection] if backup.key?(:strict_recursion_detection)
        @observability_enabled = backup[:observability_enabled] if backup.key?(:observability_enabled)
        @structured_logging_enabled = backup[:structured_logging_enabled] if backup.key?(:structured_logging_enabled)
        @structured_logging_format = backup[:structured_logging_format] if backup.key?(:structured_logging_format)
        @structured_logging_level = backup[:structured_logging_level] if backup.key?(:structured_logging_level)
        @metrics_collection_enabled = backup[:metrics_collection_enabled] if backup.key?(:metrics_collection_enabled)
        @debug_tools_enabled = backup[:debug_tools_enabled] if backup.key?(:debug_tools_enabled)
        @performance_logging_threshold = backup[:performance_logging_threshold] if backup.key?(:performance_logging_threshold)
      end
    end
  end
end

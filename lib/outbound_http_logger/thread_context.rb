# frozen_string_literal: true

module OutboundHTTPLogger
  # Encapsulates all thread-local data management for OutboundHTTPLogger
  # Provides controlled access and automatic cleanup for thread isolation
  class ThreadContext
    # User-facing attributes that can be set by application code
    USER_ATTRIBUTES = %i[
      metadata
      loggable
      config_override
    ].freeze

    # Internal state attributes used by the library itself
    INTERNAL_ATTRIBUTES = %i[
      in_faraday
      logging_error
      depth_faraday
      depth_net_http
      depth_httparty
      depth_test
      in_request
      patches_disabled
    ].freeze

    # All attributes combined
    ALL_ATTRIBUTES = (USER_ATTRIBUTES + INTERNAL_ATTRIBUTES).freeze

    # Generate thread variable names
    THREAD_VARIABLES = ALL_ATTRIBUTES.map { |attr| :"outbound_http_logger_#{attr}" }.freeze
    USER_VARIABLES = USER_ATTRIBUTES.map { |attr| :"outbound_http_logger_#{attr}" }.freeze

    class << self
      # Metaprogramming: Generate accessor methods for all attributes
      ALL_ATTRIBUTES.each do |attr_name|
        thread_var = :"outbound_http_logger_#{attr_name}"

        # Generate getter method
        define_method(attr_name) do
          Thread.current[thread_var]
        end

        # Generate setter method
        define_method(:"#{attr_name}=") do |value|
          Thread.current[thread_var] = value
        end
      end

      # Execute block with specific loggable and metadata, ensuring restoration
      # @param loggable [Object] Object to associate with outbound requests
      # @param metadata [Hash] Metadata to associate with outbound requests
      # @yield Block to execute with the specified context
      # @return [Object] Result of the yielded block
      # @example
      #   ThreadContext.with_context(loggable: user, metadata: { action: 'sync' }) do
      #     HTTParty.get('https://api.example.com')
      #   end
      def with_context(loggable: nil, metadata: {})
        backup = backup_user_context

        begin
          self.loggable = loggable if loggable
          self.metadata = metadata if metadata.any?
          yield
        ensure
          restore_user_context(backup)
        end
      end

      # Backup current complete thread context
      # @return [Hash] Hash containing all thread-local variables
      def backup_current
        THREAD_VARIABLES.each_with_object({}) do |var, backup|
          backup[var] = Thread.current[var]
        end
      end

      # Backup only user-facing context (metadata, loggable)
      # @return [Hash] Hash containing user-facing thread-local variables
      def backup_user_context
        USER_VARIABLES.each_with_object({}) do |var, backup|
          backup[var] = Thread.current[var]
        end
      end

      # Restore complete thread context from backup
      # @param backup [Hash] Hash containing thread-local variables to restore
      # @return [void]
      def restore(backup)
        THREAD_VARIABLES.each do |var|
          Thread.current[var] = backup[var]
        end
      end

      # Restore user context from backup
      # @param backup [Hash] Hash containing user-facing variables to restore
      # @return [void]
      def restore_user_context(backup)
        USER_VARIABLES.each do |var|
          Thread.current[var] = backup[var]
        end
      end

      # Clear all thread-local data
      def clear_all
        # Manually clear each variable to avoid potential constant access issues
        Thread.current[:outbound_http_logger_metadata] = nil
        Thread.current[:outbound_http_logger_loggable] = nil
        Thread.current[:outbound_http_logger_config_override] = nil
        Thread.current[:outbound_http_logger_in_faraday] = nil
        Thread.current[:outbound_http_logger_logging_error] = nil
        Thread.current[:outbound_http_logger_depth_faraday] = nil
        Thread.current[:outbound_http_logger_depth_net_http] = nil
        Thread.current[:outbound_http_logger_depth_httparty] = nil
        Thread.current[:outbound_http_logger_depth_test] = nil
        Thread.current[:outbound_http_logger_in_request] = nil
        Thread.current[:outbound_http_logger_patches_disabled] = nil
      end

      # Clear only user-facing data (metadata, loggable, config override)
      def clear_user_data
        Thread.current[:outbound_http_logger_metadata] = nil
        Thread.current[:outbound_http_logger_loggable] = nil
        Thread.current[:outbound_http_logger_config_override] = nil
      end

      # Check if any user-facing thread data is set (for isolation testing)
      def user_data_present?
        USER_VARIABLES.any? { |var| Thread.current[var] } || Thread.current[:outbound_http_logger_config_override]
      end

      # Get all current user data (for debugging/testing)
      def current_user_data
        USER_VARIABLES.each_with_object({}) do |var, data|
          value = Thread.current[var]
          data[var] = value if value
        end.tap do |data|
          config_override = Thread.current[:outbound_http_logger_config_override]
          data[:config_override] = config_override if config_override
        end
      end

      # Detect unauthorized modifications (for strict testing)
      def detect_unauthorized_modifications(expected_state = {})
        current_state = current_user_data
        unauthorized = {}

        USER_VARIABLES.each do |var|
          expected = expected_state[var]
          current = current_state[var]

          unauthorized[var] = { expected: expected, actual: current } if expected != current
        end

        unauthorized
      end

      # Internal method: Set internal state variables (used by patches)
      def set_internal(variable, value)
        raise ArgumentError, "Unknown thread variable: #{variable}" unless THREAD_VARIABLES.include?(variable)

        Thread.current[variable] = value
      end

      # Internal method: Get internal state variables (used by patches)
      def get_internal(variable)
        raise ArgumentError, "Unknown thread variable: #{variable}" unless THREAD_VARIABLES.include?(variable)

        Thread.current[variable]
      end

      # Temporarily disable patches for critical operations (like database setup)
      def with_patches_disabled
        previous_state = Thread.current[:outbound_http_logger_patches_disabled]
        Thread.current[:outbound_http_logger_patches_disabled] = true
        yield
      ensure
        Thread.current[:outbound_http_logger_patches_disabled] = previous_state
      end

      # Check if patches are currently disabled
      def patches_disabled?
        Thread.current[:outbound_http_logger_patches_disabled] == true
      end
    end
  end
end

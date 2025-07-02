# frozen_string_literal: true

module OutboundHTTPLogger
  # Standardized error handling patterns for the OutboundHTTPLogger gem
  # Ensures consistent behavior across all components and prevents logging errors
  # from interrupting parent application HTTP traffic
  module ErrorHandling
    # Standard error handling for logging operations
    # Never allows logging errors to propagate and break HTTP requests
    #
    # @param operation_name [String] Description of the operation for logging
    # @param default_return [Object] Value to return on error (default: nil)
    # @param logger [Logger] Logger instance to use for error reporting
    # @yield Block to execute with error handling
    # @return [Object] Result of block execution or default_return on error
    def self.handle_logging_error(operation_name, default_return: nil, logger: nil)
      yield
    rescue StandardError => e
      # Use provided logger or fall back to configuration logger
      error_logger = logger || OutboundHTTPLogger.configuration.get_logger

      # Log the error with context
      log_error(error_logger, operation_name, e)

      # In test environments with strict error checking, re-raise the error
      # This helps catch silent failures during testing
      raise e if strict_error_detection_enabled?

      default_return
    end

    # Standard error handling for database operations
    # Provides specific handling for common database errors
    #
    # @param operation_name [String] Description of the operation for logging
    # @param default_return [Object] Value to return on error (default: nil)
    # @param logger [Logger] Logger instance to use for error reporting
    # @yield Block to execute with error handling
    # @return [Object] Result of block execution or default_return on error
    def self.handle_database_error(operation_name, default_return: nil, logger: nil)
      yield
    rescue ActiveRecord::ConnectionNotEstablished => e
      # Specific handling for database connection issues
      error_logger = logger || OutboundHTTPLogger.configuration.get_logger
      log_connection_error(error_logger, operation_name, e)

      raise e if strict_error_detection_enabled?

      default_return
    rescue ActiveRecord::StatementInvalid => e
      # Specific handling for SQL errors
      error_logger = logger || OutboundHTTPLogger.configuration.get_logger
      log_sql_error(error_logger, operation_name, e)

      raise e if strict_error_detection_enabled?

      default_return
    rescue StandardError => e
      # Fallback for other database-related errors
      handle_logging_error(operation_name, default_return: default_return, logger: logger) { raise e }
    end

    # Standard error handling for HTTP patch operations
    # Ensures HTTP requests continue even if logging fails
    #
    # @param library_name [String] Name of the HTTP library (e.g., 'net_http')
    # @param operation_name [String] Description of the operation
    # @param logger [Logger] Logger instance to use for error reporting
    # @yield Block to execute with error handling
    # @return [Object] Result of block execution or nil on error
    def self.handle_patch_error(library_name, operation_name, logger: nil)
      yield
    rescue StandardError => e
      error_logger = logger || OutboundHTTPLogger.configuration.get_logger
      log_patch_error(error_logger, library_name, operation_name, e)

      # For patch errors, we generally don't want to re-raise even in strict mode
      # unless it's a critical configuration error
      raise e if strict_error_detection_enabled? && critical_error?(e)

      nil
    end

    # Check if strict error detection is enabled
    # Used in test environments to catch silent failures
    #
    # @return [Boolean] true if strict error detection is enabled
    def self.strict_error_detection_enabled?
      ENV['STRICT_ERROR_DETECTION'] == 'true' ||
        (OutboundHTTPLogger.configuration.respond_to?(:strict_error_detection) &&
          OutboundHTTPLogger.configuration.strict_error_detection)
    end

    # Check if an error is critical and should always be raised
    #
    # @param error [StandardError] The error to check
    # @return [Boolean] true if the error is critical
    def self.critical_error?(error)
      error.is_a?(NoMethodError) ||
        error.is_a?(ArgumentError) ||
        error.is_a?(NameError)
    end

    private_class_method def self.log_error(logger, operation_name, error)
      return unless logger

      logger.error("OutboundHTTPLogger: #{operation_name} failed: #{error.class}: #{error.message}")
      logger.debug("OutboundHTTPLogger: #{operation_name} backtrace: #{error.backtrace&.first(5)&.join(', ')}")
    end

    private_class_method def self.log_connection_error(logger, operation_name, error)
      return unless logger

      logger.error("OutboundHTTPLogger: Database connection failed during #{operation_name}: #{error.message}")
      logger.warn('OutboundHTTPLogger: Check database configuration and connectivity')
    end

    private_class_method def self.log_sql_error(logger, operation_name, error)
      return unless logger

      logger.error("OutboundHTTPLogger: SQL error during #{operation_name}: #{error.message}")
      logger.debug("OutboundHTTPLogger: SQL error details: #{error.sql}") if error.respond_to?(:sql)
    end

    private_class_method def self.log_patch_error(logger, library_name, operation_name, error)
      return unless logger

      logger.error("OutboundHTTPLogger: #{library_name} patch error during #{operation_name}: #{error.class}: #{error.message}")
      logger.warn('OutboundHTTPLogger: HTTP requests will continue but may not be logged')
    end
  end
end

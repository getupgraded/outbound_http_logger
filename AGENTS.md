# OutboundHttpLogger - Agent Development Guide

This document provides guidance for AI agents and developers working on the OutboundHttpLogger gem. It explains non-standard patterns, design decisions, and implementation details that may not be immediately obvious.

## Architecture Overview

The OutboundHttpLogger gem is designed for production-safe outbound HTTP request logging with the following key principles:

1. **Failsafe Operation**: HTTP requests must never fail due to logging errors
2. **Thread Safety**: Full support for multi-threaded applications and parallel testing
3. **Performance**: Minimal overhead with early-exit logic and deferred calls
4. **Security**: Automatic filtering of sensitive data
5. **Flexibility**: Support for multiple HTTP libraries and database adapters

## Design Patterns and Justifications

### 1. Thread-Safe Configuration System

The gem implements a simple thread-safe configuration system for parallel testing:

```ruby
# Thread-safe temporary configuration override
OutboundHttpLogger.with_configuration(enabled: true, debug_logging: true) do
  # Configuration changes only affect current thread
  # Automatically restored when block exits
  # Safe for parallel testing
end
```

**Rule**: Use `with_configuration` for temporary configuration changes in tests. This creates a complete configuration copy for the current thread.

### 2. Thread-Local Storage

```ruby
Thread.current[:outbound_http_logger_metadata] = metadata
Thread.current[:outbound_http_logger_loggable] = object
Thread.current[:outbound_http_logger_config_override] = config
```

**Justification**: Thread-local variables ensure that concurrent requests and tests don't interfere with each other. Each thread maintains its own context for metadata, loggable associations, and configuration overrides.

### 3. Configuration Backup and Restore

The Configuration class provides built-in backup and restore methods:

```ruby
# Create backup
backup = config.backup

# Modify configuration
config.enabled = true
config.max_body_size = 5000

# Restore from backup
config.restore(backup)
```

**Justification**: This pattern enables safe temporary configuration changes without losing the original state. Essential for thread-safe configuration overrides and testing.

### 4. Failsafe Error Handling

All logging operations are wrapped in rescue blocks to ensure HTTP requests never fail:

```ruby
def log_request(request, response)
  # Logging logic here
rescue StandardError => e
  # Log error but don't re-raise
  logger&.error("OutboundHttpLogger error: #{e.message}")
end
```

**Rule**: Never allow logging errors to propagate and break HTTP requests. Always use failsafe error handling in production code paths.

### 5. Early-Exit Logic

Configuration checks are performed early to avoid unnecessary processing:

```ruby
def should_log_request?(url)
  return false unless configuration.enabled?
  return false unless configuration.should_log_url?(url)
  # Additional checks...
end
```

**Justification**: Performance optimization that minimizes overhead when logging is disabled or requests are excluded.

## Testing Patterns

### 1. Thread-Safe Test Configuration

```ruby
# Using test helper for thread-safe configuration
def test_logging_behavior
  with_thread_safe_configuration(enabled: true, max_body_size: 5000) do
    # Test code here
  end
end
```

**Rule**: Use `with_configuration` or `with_thread_safe_configuration` for parallel testing. Never use global configuration mutations in multi-threaded test environments.

### 2. Test Framework Integration

```ruby
# Minitest helpers
def setup_outbound_http_logger_test
  OutboundHttpLogger::Test.configure
  OutboundHttpLogger::Test.enable!
end

# RSpec helpers
RSpec.configure do |config|
  config.include OutboundHttpLogger::Test::Helpers
end
```

**Rule**: Use the provided test helpers for consistent test setup across different frameworks.

### 3. Isolation and Cleanup

```ruby
def teardown
  OutboundHttpLogger.disable!
  OutboundHttpLogger.clear_thread_data
end
```

**Rule**: Always clean up thread-local data and reset configuration state between tests to ensure proper isolation.

## Database Patterns

### 1. Adapter Pattern for Database Support

The gem uses adapter classes for different database types:

```ruby
class PostgresqlAdapter
  def create_table
    # PostgreSQL-specific table creation with JSONB
  end
end

class SqliteAdapter
  def create_table
    # SQLite-specific table creation with TEXT
  end
end
```

**Justification**: Different databases have different optimal storage types (JSONB vs TEXT) and indexing strategies.

### 2. Secondary Database Support

```ruby
# Optional secondary database for logging
OutboundHttpLogger.enable_secondary_logging!(
  'postgresql://localhost/outbound_logs',
  adapter: :postgresql
)
```

**Justification**: Allows separation of logging data from main application database for performance, analytics, or compliance reasons.

## Security Patterns

### 1. Automatic Data Filtering

```ruby
def filter_headers(headers)
  headers.each do |key, value|
    if sensitive_headers.any? { |sensitive| key.downcase.include?(sensitive) }
      headers[key] = '[FILTERED]'
    end
  end
end
```

**Rule**: Always filter sensitive data before storage. Use configurable patterns for flexibility.

### 2. Body Size Limits

```ruby
def filter_body(body)
  return body if body.length <= max_body_size
  body.truncate(max_body_size)
end
```

**Justification**: Prevents memory issues and database bloat from large response bodies.

## Performance Considerations

### 1. Deferred Execution

```ruby
# Defer expensive operations until actually needed
def request_body
  @request_body ||= expensive_body_processing
end
```

**Rule**: Use lazy evaluation for expensive operations that may not be needed.

### 2. Minimal Overhead

```ruby
# Check enabled state first to avoid unnecessary work
return unless OutboundHttpLogger.enabled?
```

**Rule**: Always check if logging is enabled before performing any logging-related work.

## Common Pitfalls

1. **Don't modify global configuration in tests** - Use `with_configuration` instead
2. **Don't forget error handling** - All logging code must be failsafe
3. **Don't ignore thread safety** - Use thread-local variables for request-specific data
4. **Don't skip data filtering** - Always filter sensitive information
5. **Don't block HTTP requests** - Logging errors must not propagate

## Development Guidelines

1. **Test thread safety** - Always test concurrent access patterns
2. **Verify failsafe behavior** - Test that logging errors don't break HTTP requests
3. **Check performance impact** - Measure overhead of logging operations
4. **Validate security filtering** - Ensure sensitive data is properly filtered
5. **Test database adapters** - Verify functionality across different database types

This guide should be updated as new patterns emerge or existing patterns change.

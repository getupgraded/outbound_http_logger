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

### 2. Thread-Safe Patch Application

**Critical Production Safety**: All HTTP library patches use mutex synchronization to prevent race conditions during concurrent patch application:

```ruby
module NetHTTPPatch
  @mutex = Mutex.new
  @applied = false

  def self.apply!
    @mutex.synchronize do
      return if @applied
      return unless defined?(Net::HTTP)

      Net::HTTP.prepend(InstanceMethods)
      @applied = true
    end
  end
end
```

**Justification**: Without mutex protection, multiple threads could simultaneously check `@applied` (both see false) and both proceed to apply the patch, leading to multiple prepends and potential issues.

### 3. Thread-Safe Configuration Backup/Restore

Configuration backup and restore operations are protected by mutex to prevent race conditions:

```ruby
def backup
  @mutex.synchronize do
    { enabled: @enabled, excluded_urls: @excluded_urls.dup, ... }
  end
end

def restore(backup)
  @mutex.synchronize do
    @enabled = backup[:enabled]
    @excluded_urls = backup[:excluded_urls]
    # ...
  end
end
```

**Rule**: All shared state modifications must be protected by appropriate synchronization mechanisms.

### 4. Thread-Safe Configuration Initialization

Global configuration initialization uses mutex protection to prevent race conditions:

```ruby
module OutboundHttpLogger
  @config_mutex = Mutex.new

  def self.global_configuration
    @config_mutex.synchronize do
      @configuration ||= Configuration.new
    end
  end
end
```

**Critical Issue**: The `@configuration ||= Configuration.new` pattern is a classic check-then-act race condition. Multiple threads could simultaneously see `@configuration` as nil and both create new Configuration instances, leading to lost configuration state.

**Rule**: All lazy initialization patterns must use proper synchronization to prevent race conditions in multi-threaded environments.

### 5. Thread-Local Variable Leak Prevention

**Critical Issue**: Early returns in HTTP patches can bypass `ensure` blocks, causing thread-local variable leaks:

```ruby
# BEFORE (THREAD-LOCAL LEAK)
Thread.current[:outbound_http_logger_in_faraday] = true
begin
  # ... processing ...
  return super unless should_log_url?(url)  # ⚠️ LEAK! ensure never reached
ensure
  Thread.current[:outbound_http_logger_in_faraday] = false  # Never executed
end

# AFTER (LEAK-PROOF)
# Check conditions BEFORE setting thread-local variable
return super unless should_log_url?(url)

Thread.current[:outbound_http_logger_in_faraday] = true
begin
  # ... processing (no early returns) ...
ensure
  Thread.current[:outbound_http_logger_in_faraday] = false  # Always executed
end
```

**Impact**: Thread-local variable leaks cause all subsequent requests in that thread to be silently skipped, leading to missing logs and test failures.

**Rule**: Set thread-local variables only after all early-exit conditions are checked, or ensure cleanup always occurs regardless of exit path.

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

### 3. Database Connection Management for Secondary Databases

The gem implements a careful approach to database connections that respects Rails' multi-database architecture:

```ruby
# ✅ Correct - Add configuration without establishing primary connection
ActiveRecord::Base.configurations.configurations << ActiveRecord::DatabaseConfigurations::HashConfig.new(
  env_name,
  connection_name.to_s,
  config
)

# ✅ Correct - Dynamic model classes with custom connection method
klass = Class.new(OutboundHttpLogger::Models::OutboundRequestLog) do
  @adapter_connection_name = adapter_connection_name

  def self.connection
    ActiveRecord::Base.connection_handler.retrieve_connection(@adapter_connection_name.to_s)
  end
end

# ❌ Wrong - Direct establish_connection interferes with Rails
klass.establish_connection(connection_name)

# ❌ Wrong - connects_to doesn't work with non-abstract classes
klass.connects_to database: { writing: connection_name }
```

**Critical Rules for Secondary Database Support**:

1. **Never use `establish_connection` on model classes** - This can interfere with Rails' primary database configuration and multi-database setups
2. **Add configurations to Rails but don't establish connections** - Let Rails manage connection establishment through its normal mechanisms
3. **Use custom connection methods for secondary databases** - Override the `connection` method to retrieve the correct connection from Rails' connection handler
4. **Inherit from main model classes** - Dynamic adapter model classes should inherit from the main model to get all instance methods like `formatted_call`

**Rationale**: Rails applications often use multiple databases (primary, read replicas, logging databases, etc.). The gem must not interfere with the main application's database configuration. By adding configurations without establishing connections, we let Rails handle connection pooling, failover, and multi-database routing properly.

**Rule**: Leverage Rails' connection pooling and multi-database support. Never manage database connections manually or interfere with the main application's database setup.

### 4. Safe Connection Handling and Failure Modes

The gem must handle database connection issues gracefully without breaking the parent application:

```ruby
# ✅ Correct - Explicit connection handling with safe failures
def log_request(...)
  return unless enabled?

  begin
    model_class.create!(request_data)
  rescue ActiveRecord::ConnectionNotEstablished => e
    # Log error but don't crash the app
    logger.error "OutboundHttpLogger: Database connection failed: #{e.message}"
    return false
  rescue StandardError => e
    # Log unexpected errors but don't crash the app
    logger.error "OutboundHttpLogger: Failed to log request: #{e.message}"
    return false
  end
end

# ✅ Correct - Explicit connection configuration
def connection
  if @adapter_connection_name
    # Use configured named connection - fail explicitly if not available
    ActiveRecord::Base.connection_handler.retrieve_connection(@adapter_connection_name.to_s)
  else
    # Use default connection when explicitly configured to do so
    ActiveRecord::Base.connection
  end
rescue ActiveRecord::ConnectionNotEstablished => e
  # Don't fall back silently - log the specific issue
  logger.error "OutboundHttpLogger: Cannot retrieve connection '#{@adapter_connection_name}': #{e.message}"
  raise
end

# ❌ Wrong - Silent fallbacks mask configuration issues
def connection
  ActiveRecord::Base.connection_handler.retrieve_connection(@adapter_connection_name.to_s)
rescue ActiveRecord::ConnectionNotEstablished
  # This hides real configuration problems!
  ActiveRecord::Base.connection
end
```

**Critical Connection Handling Rules**:

1. **No Silent Fallbacks**: If configured to use a named connection, use only that connection. Don't fall back to default connection silently.

2. **Explicit Configuration**: Make it clear in configuration whether to use default or named connection.

3. **Safe Startup Failures**: During gem initialization, connection failures can raise errors (but catch them in the gem's initialization code).

4. **Safe Runtime Failures**: During request logging, connection failures should log errors but never crash the parent application.

5. **Clear Error Messages**: Log specific connection names and error details to aid debugging.

6. **Test Explicit Configuration**: In tests, explicitly configure which connection strategy to use rather than relying on fallbacks.

**Rationale**: Silent fallbacks between database connections can mask serious configuration issues in production. If a gem is configured to use a specific database connection, it should use exactly that connection or fail with a clear error message. This makes configuration problems obvious during development and testing rather than causing subtle issues in production.

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

## Systematic Debugging and Test Isolation

### Test Isolation Debugging Methodology

When tests fail when run together but pass individually, use systematic debugging:

**❌ Don't**: Immediately revert to running tests individually
**✅ Do**: Find the exact root cause through systematic investigation

#### Debugging Process:

1. **Test individual files** to confirm they work in isolation
2. **Test pairs/combinations** to identify problematic interactions
3. **Check configuration state** after each test file
4. **Identify the specific conflict** (configuration, thread-local data, dependencies)
5. **Fix the root cause** rather than masking with workarounds

#### Common Test Isolation Issues:

1. **Configuration Conflicts**:
   ```ruby
   # Problem: Tests leaving configuration in bad state
   # Solution: Proper setup/teardown with reset_configuration!

   def setup
     OutboundHttpLogger.reset_configuration!
   end

   def teardown
     OutboundHttpLogger.disable!
     OutboundHttpLogger.clear_all_thread_data
   end
   ```

2. **Logger Dependencies**:
   ```ruby
   # Problem: Tests enabling logging without setting proper logger
   # Solution: Always set test logger to avoid Rails.logger fallback

   def with_logging_enabled
     OutboundHttpLogger.configure do |config|
       config.enabled = true
       config.logger = Logger.new(StringIO.new) unless config.logger
     end
     yield
   ensure
     OutboundHttpLogger.disable!
   end
   ```

3. **Configuration Method Conflicts**:
   ```ruby
   # Problem: Mixing configuration approaches
   OutboundHttpLogger.with_configuration(enabled: true) do
     with_logging_enabled do  # This creates conflicts!

   # Solution: Use single, consistent approach
   OutboundHttpLogger.with_configuration(enabled: true, logger: Logger.new(StringIO.new)) do
   ```

### Test File Organization

**Rakefile Pattern**:
```ruby
# ✅ Automatic test discovery (recommended)
t.test_files = FileList["test/**/*test*.rb"].exclude(
  "test/test_helper.rb",           # Helper file, not a test
  "test/test_database_adapters.rb", # Requires Rails environment
  "test/test_recursion_detection.rb" # Requires Rails.logger
)

# ❌ Manual test file lists (maintenance burden)
t.test_files = ["test/patches/test_*.rb", "test/concerns/test_*.rb", ...]
```

**Benefits of automatic discovery**:
- New test files are automatically included
- No maintenance burden of updating file lists
- Consistent with standard Ruby testing practices

### Isolation Checking

Enable strict isolation checking in CI:
```bash
STRICT_TEST_ISOLATION=true bundle exec rake test
```

This detects:
- Leftover thread-local data
- Configuration changes not properly cleaned up
- State leakage between tests

## Common Pitfalls

1. **Don't modify global configuration in tests** - Use `with_configuration` instead
2. **Don't forget error handling** - All logging code must be failsafe
3. **Don't ignore thread safety** - Use thread-local variables for request-specific data
4. **Don't skip data filtering** - Always filter sensitive information
5. **Don't block HTTP requests** - Logging errors must not propagate
6. **Don't use `establish_connection` on secondary database models** - Interferes with Rails multi-database setup
7. **Don't use `connects_to` with non-abstract model classes** - Causes "not allowed" errors
8. **Don't use file-based test databases without cleanup** - Use in-memory SQLite for better performance
9. **Don't use silent fallbacks between database connections** - Masks configuration issues and causes production problems
10. **Don't let database errors crash the parent application** - Always handle connection and query errors gracefully

## Development Guidelines

1. **Test thread safety** - Always test concurrent access patterns
2. **Verify failsafe behavior** - Test that logging errors don't break HTTP requests
3. **Check performance impact** - Measure overhead of logging operations
4. **Validate security filtering** - Ensure sensitive data is properly filtered
5. **Test database adapters** - Verify functionality across different database types

## Summary

This document captures the key design decisions and patterns used in OutboundHttpLogger. When working on this codebase:

1. **Always prioritize production safety** - HTTP requests must never fail due to logging
2. **Maintain thread safety** - Use proper synchronization and thread-local storage
3. **Follow the adapter pattern** - Keep database logic isolated and testable
4. **Use dependency injection** - Avoid direct Rails dependencies in core logic
5. **Implement comprehensive error handling** - Log errors but never propagate them
6. **Debug systematically** - Find root causes rather than masking with workarounds
7. **Test thoroughly** - Use both unit tests and integration tests with real HTTP libraries

The patterns documented here ensure the gem remains reliable, performant, and maintainable in production environments.

This guide should be updated as new patterns emerge or existing patterns change.

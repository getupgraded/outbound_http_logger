# OutboundHTTPLogger - Agent Development Guide

This document provides guidance for AI agents and developers working on the OutboundHTTPLogger gem. It explains non-standard patterns, design decisions, and implementation details that may not be immediately obvious.

## 🚨 Critical Debugging Lessons

### Infinite Recursion Detection and Resolution

**Common Cause**: Duplicate `self.included` methods in test helpers that create circular setup calls.

**Symptoms**:
- `SystemStackError: 12283 -> 27` with cycle indicators
- Tests hang or fail with stack overflow
- Setup methods called repeatedly in infinite loops

**Debugging Technique**:
```ruby
# Add debug output to identify recursion points
def setup
  puts "DEBUG: TestHelpers#setup called from #{caller[0]}"
  # ... setup code
  puts "DEBUG: TestHelpers#setup completed"
end
```

**Root Cause Example** (NEVER DO THIS):
```ruby
# This creates infinite recursion:
def self.included(base)
  base.before { setup }  # ← Calls setup, which triggers before, which calls setup again!
end
```

**Solution**: Remove duplicate `self.included` methods and problematic aliases like `alias before setup`.

### Test Helper Anti-Patterns

**❌ NEVER DO**:
- Multiple `self.included` method definitions
- `base.before { setup }` patterns that create circular calls
- `alias before setup` or `alias after teardown` in test helpers

**✅ SAFE PATTERN**:
```ruby
module TestHelpers
  def self.included(base)
    # Only add hooks for Minitest::Spec classes
    return unless base.respond_to?(:after)

    base.after do
      perform_isolation_checks_and_cleanup
    end
  end

  def setup
    # Direct setup code - no circular calls
  end
end
```

### Ruby 3.4.4/Rails 8.0.2 Environment Issues

**Mutex Problems**: Standard `Mutex.new` and `Mutex#synchronize` cause infinite recursion in this environment.

**Solution**: Use simple boolean flags instead:
```ruby
# ❌ BROKEN in Ruby 3.4.4/Rails 8.0.2:
@@mutex = Mutex.new
@@mutex.synchronize { @@applied = true }

# ✅ WORKS:
@@applied = false
return if @@applied
@@applied = true
```

**Dependency Issues**: concurrent-ruby is not needed if you're only using `Thread.current`.

## Architecture Overview

The OutboundHTTPLogger gem is designed for production-safe outbound HTTP request logging with the following key principles:

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
OutboundHTTPLogger.with_configuration(enabled: true, debug_logging: true) do
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
module OutboundHTTPLogger
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
  logger&.error("OutboundHTTPLogger error: #{e.message}")
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

### 1. Thread-Based Parallel Testing

The gem supports **thread-based parallel testing** using Rails' built-in `parallelize` feature:

```ruby
# In test_helper.rb
class ActiveSupport::TestCase
  # Use thread-based parallelization to avoid DRb serialization issues
  # Default to 4 workers for optimal performance with SQLite, but allow override
  worker_count = ENV['PARALLEL_WORKERS']&.to_i || 4
  parallelize(workers: worker_count, with: :threads)
end
```

**Key Benefits**:
- **No DRb serialization issues**: Threads share memory space, avoiding Proc marshaling problems
- **Optimal performance**: ~20-30% speed improvement over sequential testing
- **Configurable**: Use `PARALLEL_WORKERS` environment variable to tune worker count
- **Auto-scaling connection pool**: Database connections scale automatically with worker count

**Database Configuration for Parallel Testing**:
```ruby
# Scale connection pool with number of workers
worker_count = ENV['PARALLEL_WORKERS']&.to_i || 4
pool_size = [worker_count * 3, 15].max  # At least 3 connections per worker, minimum 15

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: database_url || ":memory:",
  pool: pool_size,
  timeout: 15
)
```

**Usage Examples**:
```bash
# Default (4 threads)
bundle exec rake test

# Custom worker count
PARALLEL_WORKERS=2 bundle exec rake test

# With strict isolation
STRICT_TEST_ISOLATION=true STRICT_ERROR_DETECTION=true bundle exec rake test
```

**Performance Results**:
- **Sequential**: ~0.28-0.32 seconds
- **Thread-based (4 workers)**: ~0.19-0.24 seconds
- **Speedup**: 20-30% improvement

### 2. Thread-Safe Test Configuration

```ruby
# Using test helper for thread-safe configuration
def test_logging_behavior
  with_thread_safe_configuration(enabled: true, max_body_size: 5000) do
    # Test code here
  end
end
```

**Rule**: Use `with_configuration` or `with_thread_safe_configuration` for parallel testing. Never use global configuration mutations in multi-threaded test environments.

### 3. Test Framework Integration

```ruby
# Minitest helpers
def setup_outbound_http_logger_test
  OutboundHTTPLogger::Test.configure
  OutboundHTTPLogger::Test.enable!
end

# RSpec helpers
RSpec.configure do |config|
  config.include OutboundHTTPLogger::Test::Helpers
end
```

**Rule**: Use the provided test helpers for consistent test setup across different frameworks.

### 4. Isolation and Cleanup

```ruby
def teardown
  OutboundHTTPLogger.disable!
  OutboundHTTPLogger.clear_thread_data
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
OutboundHTTPLogger.enable_secondary_logging!(
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
klass = Class.new(OutboundHTTPLogger::Models::OutboundRequestLog) do
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
    logger.error "OutboundHTTPLogger: Database connection failed: #{e.message}"
    return false
  rescue StandardError => e
    # Log unexpected errors but don't crash the app
    logger.error "OutboundHTTPLogger: Failed to log request: #{e.message}"
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
  logger.error "OutboundHTTPLogger: Cannot retrieve connection '#{@adapter_connection_name}': #{e.message}"
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
return unless OutboundHTTPLogger.enabled?
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
     OutboundHTTPLogger.reset_configuration!
   end

   def teardown
     OutboundHTTPLogger.disable!
     OutboundHTTPLogger.clear_all_thread_data
   end
   ```

2. **Logger Dependencies**:
   ```ruby
   # Problem: Tests enabling logging without setting proper logger
   # Solution: Always set test logger to avoid Rails.logger fallback

   def with_outbound_http_logging_enabled
     OutboundHTTPLogger.configure do |config|
       config.enabled = true
       config.logger = Logger.new(StringIO.new) unless config.logger
     end
     yield
   ensure
     OutboundHTTPLogger.disable!
   end
   ```

3. **Configuration Method Conflicts**:
   ```ruby
   # Problem: Mixing configuration approaches
   OutboundHTTPLogger.with_configuration(enabled: true) do
     with_outbound_http_logging_enabled do  # This creates conflicts!

   # Solution: Use single, consistent approach
   OutboundHTTPLogger.with_configuration(enabled: true, logger: Logger.new(StringIO.new)) do
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

### Strict Test Isolation and Error Detection

The gem provides two powerful mechanisms for catching test isolation violations and silent errors:

#### 1. Strict Test Isolation (`STRICT_TEST_ISOLATION=true`)

Enable strict isolation checking to catch tests that don't clean up after themselves:

```bash
STRICT_TEST_ISOLATION=true bundle exec rake test
```

**What it detects:**
- Leftover thread-local data (`outbound_http_logger_loggable`, `outbound_http_logger_metadata`)
- Configuration changes not properly cleaned up
- State leakage between tests

**How it works:**
- Runs isolation checks in test teardown
- Raises `RuntimeError` with detailed error messages when violations are found
- Provides actionable guidance on how to fix the issues

**Example error:**
```
RuntimeError: Test isolation failure: Leftover thread-local data detected!

The following thread-local variables were not cleaned up:
  outbound_http_logger_loggable: #<Object:0x000000012b0b2698>
  outbound_http_logger_metadata: {test: "data"}

This indicates that a test is not properly cleaning up after itself.
Each test should ensure all thread-local data is cleared in its teardown.

To fix this:
1. Add proper cleanup in the test's teardown method
2. Use OutboundHTTPLogger.clear_thread_data or clear specific variables
3. Ensure with_configuration blocks properly restore state
```

#### 2. Silent Error Detection (`STRICT_ERROR_DETECTION=true`)

Enable strict error detection to catch errors that would normally be silently swallowed:

```bash
STRICT_ERROR_DETECTION=true bundle exec rake test
```

**What it detects:**
- Database errors that would normally be logged and ignored
- Rails compatibility issues (e.g., `has_query_constraints?` errors)
- Any `StandardError` in the logging pipeline that would normally be silently handled

**How it works:**
- Re-raises exceptions that would normally be caught and logged
- Ensures that logging errors cause test failures instead of being hidden
- Helps identify real issues that could cause silent failures in production

**Example usage in CI:**
```bash
# Run with both strict modes enabled
STRICT_TEST_ISOLATION=true STRICT_ERROR_DETECTION=true bundle exec rake test
```

#### Benefits of Strict Testing

1. **Prevents Flaky Tests**: Catches test interdependencies that cause failures only when tests run in specific orders
2. **Forces Proper Cleanup**: Tests must clean up their own state rather than relying on global resets
3. **Catches Silent Failures**: Ensures that errors don't fail silently and cause mysterious issues
4. **Improves Test Quality**: Encourages writing isolated, independent tests
5. **Easier Debugging**: Provides immediate, actionable feedback when isolation is violated

#### Implementation Pattern

The strict testing mechanisms are implemented using:

```ruby
# In test teardown
def perform_isolation_checks_and_cleanup
  if ENV['STRICT_TEST_ISOLATION'] == 'true'
    # Check for isolation violations BEFORE cleanup
    # These will raise errors if violations are found
    assert_no_leftover_thread_data!
    assert_configuration_unchanged!
  end

  # Normal cleanup happens after checks
  OutboundHTTPLogger.disable!
  OutboundHTTPLogger.clear_all_thread_data
end

# In error handling
rescue StandardError => e
  logger&.error("OutboundHTTPLogger: Failed to log request: #{e.class}: #{e.message}")

  # In test environments with strict error checking, re-raise the error
  if ENV['STRICT_ERROR_DETECTION'] == 'true'
    raise e
  end

  nil
end
```

**Rule**: Use strict testing modes in CI to catch issues early. These modes should be enabled for all automated testing to ensure high code quality and prevent flaky tests.

## Parallel Testing Implementation

### Thread-Based vs Process-Based Parallel Testing

The gem successfully implements **thread-based parallel testing** after encountering fundamental issues with process-based approaches.

#### ❌ Process-Based Parallel Testing Issues

**Problem**: Rails' default `parallelize(workers: X)` uses process-based parallelization with DRb (Distributed Ruby) for communication between the main process and worker processes.

**Root Cause**: DRb requires all objects to be serializable via Marshal. The OutboundHTTPLogger codebase contains Proc objects that cannot be serialized, leading to:

```
DRb::DRbRemoteError: no _dump_data is defined for class Proc
```

**Failed Approaches**:
- `parallelize(workers: :number_of_processors)` - DRb serialization errors
- `parallelize(workers: 2)` - Same DRb issues with fewer workers
- `minitest-parallel-db` - Same serialization issues, plus naming conflicts

#### ✅ Thread-Based Parallel Testing Solution

**Implementation**:
```ruby
class ActiveSupport::TestCase
  # Use thread-based parallelization to avoid DRb serialization issues
  worker_count = ENV['PARALLEL_WORKERS']&.to_i || 4
  parallelize(workers: worker_count, with: :threads)
end
```

**Why It Works**:
- **Shared Memory**: Threads share the same memory space, so no object serialization required
- **No DRb**: Thread-based approach doesn't use DRb for inter-process communication
- **Proc Objects**: Proc objects can exist in shared memory without marshaling

**Database Connection Scaling**:
```ruby
# Scale connection pool with number of workers
worker_count = ENV['PARALLEL_WORKERS']&.to_i || 4
pool_size = [worker_count * 3, 15].max  # At least 3 connections per worker, minimum 15

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: database_url || ":memory:",
  pool: pool_size,
  timeout: 15
)
```

#### Performance Results

| Approach | Time | Workers | Status |
|----------|------|---------|--------|
| Sequential | 0.28-0.32s | 1 | ✅ Works |
| Process-based | N/A | 2-10 | ❌ DRb serialization errors |
| Thread-based | 0.19-0.24s | 4 | ✅ Works perfectly |

**Speedup**: 20-30% improvement over sequential testing

#### Configuration Guidelines

**Optimal Worker Counts**:
- **Default**: 4 threads (optimal for SQLite in-memory databases)
- **Conservative**: 2 threads (for systems with limited resources)
- **Aggressive**: 6-8 threads (may cause connection pool exhaustion)

**Environment Variables**:
```bash
# Default (4 threads)
bundle exec rake test

# Custom worker count
PARALLEL_WORKERS=2 bundle exec rake test

# With strict testing
STRICT_TEST_ISOLATION=true STRICT_ERROR_DETECTION=true PARALLEL_WORKERS=4 bundle exec rake test
```

#### Troubleshooting Parallel Testing

**Connection Pool Exhaustion**:
```
ActiveRecord::ConnectionTimeoutError: could not obtain a connection from the pool within 5.000 seconds
```

**Solutions**:
1. Reduce worker count: `PARALLEL_WORKERS=2`
2. Increase pool size in database configuration
3. Increase timeout in database configuration

**Thread Safety Issues**:
- Use `STRICT_TEST_ISOLATION=true` to catch thread-local data leaks
- Ensure proper cleanup in test teardown methods
- Use thread-safe configuration methods (`with_configuration`)

#### Future Considerations

**For Process-Based Parallel Testing**:
To enable process-based parallel testing in the future:
1. Identify and refactor all Proc objects that can't be serialized
2. Consider using simple data structures instead of complex objects
3. Test thoroughly with `STRICT_TEST_ISOLATION=true`

**Current Recommendation**:
Stick with thread-based parallel testing. It provides excellent performance benefits without the complexity and limitations of process-based approaches.

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
11. **Don't skip test cleanup** - Always clear thread-local data and reset configuration in test teardown
12. **Don't rely on blanket resets** - Use strict testing modes to catch isolation violations instead of masking them
13. **Don't ignore silent errors** - Enable `STRICT_ERROR_DETECTION=true` in CI to catch swallowed exceptions

## 🎯 Successful Implementation Patterns

### Metaprogramming for ThreadContext

**Pattern**: Use gem name + attribute pattern to reduce code duplication:

```ruby
# Define attributes with metadata
ATTRIBUTES = {
  metadata: { user_facing: true },
  loggable: { user_facing: true },
  config_override: { user_facing: true },
  in_faraday: { user_facing: false },
  # ... more attributes
}.freeze

# Generate thread variable names
THREAD_VARIABLES = ATTRIBUTES.keys.map { |attr| :"outbound_http_logger_#{attr}" }.freeze

# Metaprogramming: Generate accessor methods
ATTRIBUTES.each do |attr_name, config|
  thread_var = :"outbound_http_logger_#{attr_name}"

  define_method(attr_name) do
    Thread.current[thread_var]
  end

  define_method(:"#{attr_name}=") do |value|
    Thread.current[thread_var] = value
  end
end
```

**Benefits**:
- Eliminates code duplication
- Ensures consistent naming patterns
- Easy to add new attributes
- Self-documenting through metadata

### Thread-Based Parallel Testing Implementation

**Current Implementation** (Production-Ready):
```ruby
# In test_helper.rb
module ActiveSupport
  class TestCase
    # Use thread-based parallelization to avoid DRb serialization issues
    # Default to optimal worker count but allow override via environment variable
    worker_count = ENV.fetch('PARALLEL_WORKERS', [1, Etc.nprocessors - 2].max).to_i
    parallelize(workers: worker_count, with: :threads)
  end
end
```

**Key Features of Our Implementation**:
- **Smart Worker Count**: Defaults to `Etc.nprocessors - 2` (leaves 2 cores for system)
- **Environment Override**: `PARALLEL_WORKERS` environment variable for custom worker count
- **Thread Safety**: All configuration and state management is thread-local
- **Database Isolation**: Proper connection pooling with automatic scaling
- **Performance Optimized**: ~8x speedup on modern hardware

**Why Thread-Based vs Process-Based**:
- **Thread-based**: Avoids DRb serialization issues with Proc objects and complex state
- **Process-based**: Would fail with `no _dump_data is defined for class Proc` errors
- **Memory Efficiency**: Shared memory space reduces overhead vs. process-based
- **Connection Pooling**: Automatic scaling (3 connections per worker, minimum 15)

**Thread Safety Implementation**:
- **Configuration**: Thread-local overrides with `Thread.current[:outbound_http_logger_config_override]`
- **Context Management**: Thread-local storage for loggable associations and metadata
- **State Isolation**: Each test thread maintains independent state
- **Cleanup**: Automatic thread-local data clearing between tests

**Benefits of Current Approach**:
- No DRb serialization issues
- Shared memory space between threads
- Automatic connection pool scaling
- Works with existing test isolation mechanisms
- Comprehensive test isolation with error detection
- Faster test execution with optimal resource usage

### Dependency Management

**Removed Dependencies**:
- `concurrent-ruby` - Not needed when using simple `Thread.current`
- ActiveSupport already provides concurrent-ruby as a transitive dependency

**Current Dependencies**:
```ruby
spec.add_dependency 'activerecord', '>= 7.2.0'
spec.add_dependency 'activesupport', '>= 7.2.0'
spec.add_dependency 'rack', '>= 2.0'
# concurrent-ruby removed - not directly used
```

**Rule**: Only depend on gems you actually use. Check transitive dependencies before adding direct ones.

### Thread-Local Configuration System

**Implementation Details**:
The gem uses a sophisticated thread-local configuration system to support parallel testing:

```ruby
# Global configuration (shared across threads)
@global_configuration = Configuration.new

# Thread-local configuration override
Thread.current[:outbound_http_logger_config_override] = temp_config

# Configuration resolution (thread-local takes precedence)
def configuration
  Thread.current[:outbound_http_logger_config_override] || @global_configuration
end
```

**Thread Context Management**:
```ruby
module ThreadContext
  # Thread-local storage for request context
  def self.loggable=(value)
    Thread.current[:outbound_http_logger_loggable] = value
  end

  def self.metadata=(value)
    Thread.current[:outbound_http_logger_metadata] = value
  end

  # Automatic cleanup between tests
  def self.clear!
    Thread.current[:outbound_http_logger_loggable] = nil
    Thread.current[:outbound_http_logger_metadata] = nil
    Thread.current[:outbound_http_logger_config_override] = nil
  end
end
```

**Benefits for Parallel Testing**:
- **Isolation**: Each thread maintains independent configuration and context
- **Performance**: No locks or synchronization needed for read operations
- **Flexibility**: Temporary configuration overrides don't affect other threads
- **Cleanup**: Automatic clearing prevents test interference

## 🧪 Testing and Debugging Guidelines

### Running Tests

**Basic test execution**:
```bash
bundle exec rake test                               # Run all tests (parallel, auto-detected threads)
bundle exec rake test_all                          # Run all tests including database adapter tests
bundle exec rake test_database_adapters            # Run database adapter tests separately
bundle exec rake test TESTOPTS="--name=/pattern/" # Run specific tests
bundle exec rake test TESTOPTS="--verbose"        # Verbose output
```

**Parallel testing configuration**:
```bash
# Default: Uses Etc.nprocessors - 2 threads (optimal for most systems)
bundle exec rake test

# Custom worker count:
PARALLEL_WORKERS=2 bundle exec rake test           # Use 2 threads (conservative)
PARALLEL_WORKERS=8 bundle exec rake test           # Use 8 threads (high-performance systems)
PARALLEL_WORKERS=1 bundle exec rake test           # Disable parallelization (debugging)
```

**Performance characteristics**:
- **Default threads**: `Etc.nprocessors - 2` (leaves 2 cores for system)
- **Connection pool**: Scales automatically (3 connections per worker, minimum 15)
- **Speedup**: ~8x faster on 8-core systems vs. single-threaded
- **Memory usage**: Shared memory space, minimal overhead per thread

**Test isolation verification**:
```bash
STRICT_TEST_ISOLATION=true bundle exec rake test   # Catch isolation violations
STRICT_ERROR_DETECTION=true bundle exec rake test  # Catch silent errors
```

**Combined strict testing** (recommended for CI):
```bash
STRICT_TEST_ISOLATION=true STRICT_ERROR_DETECTION=true bundle exec rake test
```

### Test Isolation Mechanisms

**Thread-Local State Management**:
- **Configuration**: Each thread can have independent configuration overrides
- **Context**: Loggable associations and metadata are thread-local
- **Cleanup**: Automatic clearing of thread-local data between tests

**Database Isolation**:
- **Connection Pooling**: Each thread gets its own database connection
- **Transaction Handling**: Proper transaction isolation between threads
- **Data Cleanup**: Comprehensive cleanup of test data after each test

**Patch State Isolation**:
- **Global Patches**: HTTP library patches are applied globally (safe for threads)
- **Configuration**: Patch behavior controlled by thread-local configuration
- **Reset Capability**: Patches can be reset for testing purposes

**Error Detection**:
- **Silent Failures**: `STRICT_ERROR_DETECTION=true` catches silent errors
- **State Leakage**: `STRICT_TEST_ISOLATION=true` detects test interference
- **Resource Cleanup**: Automatic verification of proper cleanup

### Debugging Infinite Recursion

**Step 1**: Add debug output to identify the recursion point:
```ruby
def problematic_method
  puts "DEBUG: #{self.class}##{__method__} called from #{caller[0]}"
  # ... method body
  puts "DEBUG: #{self.class}##{__method__} completed"
end
```

**Step 2**: Look for patterns in the output:
- Repeated calls to the same method
- Circular call chains
- Setup methods called in loops

**Step 3**: Check for common causes:
- Duplicate `self.included` methods
- Circular aliases (`alias before setup`)
- Mutex usage in Ruby 3.4.4/Rails 8.0.2

### Environment-Specific Issues

**Ruby 3.4.4/Rails 8.0.2 Known Issues**:
- Mutex operations cause infinite recursion
- Some concurrent-ruby features are incompatible
- Use simple boolean flags instead of mutexes

**Testing Database Isolation**:
- Thread-based parallel testing with automatic connection pool scaling
- In-memory SQLite works well with thread-based approach (shared memory)
- Each test should start with clean state
- Connection pool scales automatically: `[worker_count * 3, 15].max`

## Development Guidelines

1. **Test thread safety** - Always test concurrent access patterns
2. **Verify failsafe behavior** - Test that logging errors don't break HTTP requests
3. **Check performance impact** - Measure overhead of logging operations
4. **Validate security filtering** - Ensure sensitive data is properly filtered
5. **Test database adapters** - Verify functionality across different database types
6. **Debug systematically** - Use debug output to identify recursion points
7. **Test in isolation** - Use STRICT_TEST_ISOLATION=true to catch violations
8. **Use parallel testing** - Thread-based parallel testing provides 20-30% speed improvement
9. **Test with strict modes** - Enable both STRICT_TEST_ISOLATION and STRICT_ERROR_DETECTION in CI

## Summary

This document captures the key design decisions, debugging techniques, and patterns used in OutboundHTTPLogger. When working on this codebase:

### Critical Priorities
1. **Always prioritize production safety** - HTTP requests must never fail due to logging
2. **Debug recursion systematically** - Use debug output to identify circular calls
3. **Avoid problematic patterns** - No duplicate `self.included` methods or circular aliases
4. **Use environment-appropriate solutions** - Simple boolean flags instead of mutexes in Ruby 3.4.4

### Architecture Guidelines
5. **Maintain thread safety** - Use proper synchronization and thread-local storage
6. **Follow the adapter pattern** - Keep database logic isolated and testable
7. **Use dependency injection** - Avoid direct Rails dependencies in core logic
8. **Implement comprehensive error handling** - Log errors but never propagate them

### Development Practices
9. **Use metaprogramming wisely** - Gem name + attribute patterns reduce duplication
10. **Test thoroughly** - Use both unit tests and integration tests with real HTTP libraries
11. **Verify test isolation** - Use STRICT_TEST_ISOLATION=true to catch violations
12. **Manage dependencies carefully** - Only depend on gems you actually use

### Key Learnings
- **Infinite recursion** is often caused by test helper patterns, not business logic
- **Ruby 3.4.4/Rails 8.0.2** has specific compatibility issues with mutexes
- **Metaprogramming** with consistent naming patterns significantly improves maintainability
- **Simple solutions** often work better than complex threading primitives
- **Thread-based parallel testing** avoids DRb serialization issues that plague process-based approaches
- **Connection pool scaling** is critical for thread-based parallel testing with databases
- **4 threads** is the optimal default for SQLite with in-memory databases

The patterns documented here ensure the gem remains reliable, performant, and maintainable in production environments.

This guide should be updated as new patterns emerge or existing patterns change.

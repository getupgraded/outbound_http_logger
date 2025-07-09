# Thread Safety and Parallel Testing

This document explains how OutboundHTTPLogger implements thread safety and supports parallel testing.

## Overview

OutboundHTTPLogger is designed to be thread-safe and supports parallel test execution using thread-based parallelization. This design choice provides optimal performance while avoiding the complexity and limitations of process-based parallelization.

## Thread-Local Configuration System

### Global vs Thread-Local Configuration

The gem uses a two-tier configuration system:

```ruby
# Global configuration (shared across threads)
@global_configuration = Configuration.new

# Thread-local configuration override (per-thread)
Thread.current[:outbound_http_logger_config_override] = temp_config

# Configuration resolution (thread-local takes precedence)
def configuration
  Thread.current[:outbound_http_logger_config_override] || @global_configuration
end
```

### Benefits

- **Isolation**: Each thread can have independent configuration without affecting others
- **Performance**: No locks or synchronization needed for read operations
- **Flexibility**: Temporary configuration overrides for testing
- **Backward Compatibility**: Global configuration still works for single-threaded applications

## Thread Context Management

### ThreadContext Module

The `ThreadContext` module manages thread-local state for request context:

```ruby
module ThreadContext
  # Set loggable association for current thread
  def self.loggable=(value)
    Thread.current[:outbound_http_logger_loggable] = value
  end

  # Set metadata for current thread
  def self.metadata=(value)
    Thread.current[:outbound_http_logger_metadata] = value
  end

  # Clear all thread-local data
  def self.clear!
    Thread.current[:outbound_http_logger_loggable] = nil
    Thread.current[:outbound_http_logger_metadata] = nil
    Thread.current[:outbound_http_logger_config_override] = nil
  end
end
```

### Automatic Cleanup

Thread-local data is automatically cleared between tests to prevent interference:

```ruby
# In test helper
def teardown
  OutboundHTTPLogger::ThreadContext.clear!
  super
end
```

## Parallel Testing Implementation

### Thread-Based Parallelization

We use thread-based parallelization instead of process-based for several reasons:

```ruby
# In test_helper.rb
module ActiveSupport
  class TestCase
    # Use thread-based parallelization
    worker_count = ENV.fetch('PARALLEL_WORKERS', [1, Etc.nprocessors - 2].max).to_i
    parallelize(workers: worker_count, with: :threads)
  end
end
```

### Why Threads vs Processes

| Aspect | Threads | Processes |
|--------|---------|-----------|
| **Memory Usage** | Shared memory space | Separate memory per process |
| **Startup Time** | Fast | Slower due to process creation |
| **Communication** | Direct memory access | DRb serialization required |
| **Complexity** | Lower | Higher (DRb, serialization) |
| **Debugging** | Easier | More complex |
| **Resource Usage** | Lower | Higher |

### Performance Characteristics

- **Default Worker Count**: `Etc.nprocessors - 2` (leaves 2 cores for system)
- **Speedup**: ~8x faster on 8-core systems vs. single-threaded
- **Memory Overhead**: Minimal per thread (shared memory space)
- **Connection Pool**: Automatically scales (3 connections per worker, minimum 15)

## Database Connection Management

### Connection Pooling

The gem automatically configures database connection pooling for parallel tests:

```ruby
# Automatic connection pool sizing
pool_size = [worker_count * 3, 15].max
ActiveRecord::Base.establish_connection(
  ActiveRecord::Base.connection_db_config.configuration_hash.merge(pool: pool_size)
)
```

### Benefits

- **Isolation**: Each thread gets its own database connection
- **Performance**: No connection contention between threads
- **Reliability**: Proper transaction isolation
- **Scalability**: Pool size scales with worker count

## Test Isolation Mechanisms

### Configuration Isolation

Each test can have independent configuration:

```ruby
def with_outbound_http_logging_enabled
  original_config = OutboundHTTPLogger.configuration
  temp_config = OutboundHTTPLogger::Configuration.new
  temp_config.enabled = true
  
  Thread.current[:outbound_http_logger_config_override] = temp_config
  yield
ensure
  Thread.current[:outbound_http_logger_config_override] = nil
end
```

### State Isolation

Thread-local state prevents test interference:

```ruby
# Each thread maintains independent state
OutboundHTTPLogger::ThreadContext.loggable = user1  # Thread 1
OutboundHTTPLogger::ThreadContext.loggable = user2  # Thread 2
# No interference between threads
```

### Error Detection

Strict isolation checking can be enabled:

```bash
# Catch test isolation violations
STRICT_TEST_ISOLATION=true bundle exec rake test

# Catch silent errors
STRICT_ERROR_DETECTION=true bundle exec rake test
```

## HTTP Library Patches

### Global Patch Application

HTTP library patches are applied globally but behavior is controlled by thread-local configuration:

```ruby
# Patches applied once globally
Net::HTTP.prepend(OutboundHTTPLogger::Patches::NetHTTPPatch)

# Behavior controlled per-thread
def request_with_logging(request, body = nil, &block)
  return request_without_logging(request, body, &block) unless should_log?
  # Logging logic uses thread-local configuration
end
```

### Thread Safety

- **Patch Application**: Safe to apply globally (idempotent)
- **Configuration**: Thread-local configuration controls behavior
- **State**: No shared mutable state in patches
- **Performance**: No locks needed in hot path

## Best Practices

### For Application Code

1. **Use Global Configuration**: Set up global configuration once at application startup
2. **Avoid Thread-Local Overrides**: Only use for testing or special cases
3. **Trust the Defaults**: The gem handles thread safety automatically

### For Testing

1. **Use Test Helpers**: Use provided test helpers for configuration overrides
2. **Clean Up**: Always clean up thread-local state in teardown
3. **Verify Isolation**: Use strict isolation checking in CI
4. **Optimal Workers**: Use default worker count unless you have specific needs

### For Development

1. **Debug with Single Thread**: Use `PARALLEL_WORKERS=1` for debugging
2. **Monitor Performance**: Use `--verbose` to see test execution details
3. **Check Isolation**: Run with strict checking enabled periodically

## Troubleshooting

### Common Issues

1. **Test Interference**: Enable `STRICT_TEST_ISOLATION=true` to catch violations
2. **Connection Pool Exhaustion**: Increase pool size or reduce worker count
3. **Deadlocks**: Usually indicates improper cleanup - check teardown methods
4. **Inconsistent Results**: May indicate race conditions - verify thread safety

### Debugging Commands

```bash
# Single-threaded execution for debugging
PARALLEL_WORKERS=1 bundle exec rake test

# Verbose output to see test execution
bundle exec rake test TESTOPTS="--verbose"

# Strict checking to catch issues
STRICT_TEST_ISOLATION=true STRICT_ERROR_DETECTION=true bundle exec rake test
```

## Performance Tuning

### Worker Count Optimization

- **Conservative**: `PARALLEL_WORKERS=2` (safe for most systems)
- **Optimal**: Default (`Etc.nprocessors - 2`) (recommended)
- **Aggressive**: `PARALLEL_WORKERS=8+` (high-performance systems only)

### Memory Considerations

- **Shared Memory**: Threads share memory space (efficient)
- **Connection Pool**: Scales with worker count (3x workers + 15 minimum)
- **Test Data**: Clean up test data to prevent memory growth

### Database Optimization

- **Use SQLite**: In-memory SQLite for fastest test execution
- **Connection Pool**: Automatically sized for worker count
- **Transaction Isolation**: Each thread gets proper isolation

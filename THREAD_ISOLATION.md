# Thread-Local Data Isolation in OutboundHttpLogger

## Problem

Previously, the test suite used blanket cleanup of thread-local data in test setup/teardown methods. This approach masked the real problem: tests that don't clean up after themselves properly. When tests leave thread-local data behind, it can cause:

- Flaky tests that pass individually but fail when run together
- Test interference where one test's state affects another
- Difficult-to-debug issues in CI environments

## Solution

We've implemented a better approach that **detects** leftover thread-local data instead of silently cleaning it up:

### 1. Comprehensive Thread-Local Data Management

**New method: `OutboundHttpLogger.clear_all_thread_data`**
```ruby
# Clears ALL thread-local data including internal state variables
OutboundHttpLogger.clear_all_thread_data
```

This replaces the previous incomplete cleanup and ensures all thread-local variables are cleared:
- `:outbound_http_logger_metadata`
- `:outbound_http_logger_loggable`
- `:outbound_http_logger_config_override`
- `:outbound_http_logger_in_faraday`
- `:outbound_http_logger_logging_error`
- `:outbound_http_logger_depth_faraday`
- `:outbound_http_logger_depth_net_http`
- `:outbound_http_logger_depth_httparty`
- `:outbound_http_logger_depth_test`
- `:outbound_http_logger_in_request`

### 2. Isolation Checking

**New helper: `assert_no_leftover_thread_data!`**
```ruby
# In test teardown or as needed
assert_no_leftover_thread_data!
```

This method:
- Checks all known OutboundHttpLogger thread-local variables
- Raises a descriptive error if any leftover data is found
- Helps identify which tests are not cleaning up properly

### 3. Optional Strict Isolation Mode

Set the environment variable `STRICT_TEST_ISOLATION=true` to enable automatic checking in test teardown:

```bash
STRICT_TEST_ISOLATION=true bundle exec rake test
```

When enabled, the test suite will warn about leftover thread-local data after each test.

## Usage Examples

### In Test Setup/Teardown
```ruby
def teardown
  # Optional: Check for leftover data before cleanup
  if ENV['STRICT_TEST_ISOLATION'] == 'true'
    begin
      assert_no_leftover_thread_data!
    rescue => e
      puts "⚠️  #{e.message}"
    end
  end

  # Clean up
  OutboundHttpLogger.disable!
  OutboundHttpLogger.clear_all_thread_data
end
```

### Manual Isolation Testing
```ruby
def test_proper_cleanup
  # Do something that sets thread-local data
  OutboundHttpLogger.set_metadata(test: "data")
  
  # Your test logic here...
  
  # Ensure proper cleanup
  OutboundHttpLogger.clear_thread_data
  assert_no_leftover_thread_data!
end
```

### Debugging Test Isolation Issues
```ruby
def test_debugging_isolation
  # Set some data
  OutboundHttpLogger.set_metadata(debug: "info")
  
  # Intentionally forget to clean up to see the error
  assert_raises(RuntimeError) do
    assert_no_leftover_thread_data!
  end
end
```

## Benefits

1. **Proactive Problem Detection**: Instead of masking issues, we detect them early
2. **Better Test Quality**: Forces tests to properly clean up after themselves
3. **Easier Debugging**: Descriptive error messages help identify problematic tests
4. **Configurable Strictness**: Teams can enable strict checking when needed
5. **Comprehensive Cleanup**: Ensures all thread-local state is properly managed

## Migration Guide

### Before
```ruby
def setup
  # Blanket cleanup that masks problems
  Thread.current[:outbound_http_logger_config_override] = nil
  Thread.current[:outbound_http_logger_loggable] = nil
  Thread.current[:outbound_http_logger_metadata] = nil
  # ... more manual clearing
end
```

### After
```ruby
def setup
  # Use comprehensive cleanup method
  OutboundHttpLogger.clear_all_thread_data
end

def teardown
  # Optional: Check for isolation issues
  assert_no_leftover_thread_data! if ENV['STRICT_TEST_ISOLATION']
  
  # Clean up properly
  OutboundHttpLogger.clear_all_thread_data
end
```

This approach promotes better test hygiene and makes isolation issues visible rather than hidden.

## Test File Organization

### Automatic Test Discovery

The Rakefile now uses automatic test discovery instead of manual file lists:

```ruby
# ✅ Automatic discovery (recommended)
t.test_files = FileList["test/**/*test*.rb"].exclude(
  "test/test_helper.rb",           # Helper file, not a test
  "test/test_database_adapters.rb", # Requires Rails environment
  "test/test_recursion_detection.rb" # Requires Rails.logger
)

# ❌ Manual lists (maintenance burden)
t.test_files = ["test/patches/test_*.rb", "test/concerns/test_*.rb", ...]
```

**Benefits**:
- New test files are automatically included
- No maintenance burden of updating file lists
- Consistent with standard Ruby testing practices

## Logger Dependencies

### Problem: Rails.logger Fallback

Tests that enable logging without setting a proper logger cause `Rails.logger` dependency errors:

```ruby
# Problem: Enables logging but no logger set
def with_logging_enabled
  OutboundHttpLogger.enable!  # Falls back to Rails.logger
  yield
ensure
  OutboundHttpLogger.disable!
end
```

### Solution: Explicit Test Logger

Always set a test logger to avoid Rails dependencies:

```ruby
# Solution: Set explicit test logger
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

This approach eliminates Rails dependencies in test environments and ensures consistent behavior.

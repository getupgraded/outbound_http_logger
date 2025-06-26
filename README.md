# OutboundHTTPLogger

[![CI](https://github.com/getupgraded/outbound_http_logger/actions/workflows/test.yml/badge.svg)](https://github.com/getupgraded/outbound_http_logger/actions/workflows/outbound-http-logger-ci.yml)

A production-safe gem for comprehensive outbound HTTP request logging in Rails applications. Supports multiple HTTP libraries with configurable filtering and failsafe error handling.

## Features

- **Multi-library support**: Net::HTTP, Faraday, HTTParty with automatic patching
- **Database adapters**: Optimized PostgreSQL JSONB and SQLite native JSON support
- **Comprehensive logging**: Request/response headers, bodies, timing, status codes
- **Security-first**: Automatic filtering of sensitive headers and body data
- **Performance-optimized**: Early-exit logic, deferred calls, minimal overhead
- **Production-safe**: Failsafe error handling ensures HTTP requests never fail due to logging
- **Configurable exclusions**: URL patterns, content types, and custom filters
- **Secondary database support**: Optional separate database for logging
- **Test utilities**: Comprehensive test helpers and persistent test logging
- **Rollback-capable migrations**: Proper up/down migrations with optimized indexes
- **Model integration**: Associate logs with records from your ActiveRecord models

## Installation

Add to your Gemfile:

```ruby
gem 'outbound_http_logger', git: 'https://github.com/getupgraded/outbound_http_logger.git' # this is not a published gem yet
```

Run the generator to create the database migration:

```bash
rails generate outbound_http_logger:migration
rails db:migrate
```

### Compatibility

This gem supports Ruby versions **3.2** and newer and is tested against
Ruby 3.2, 3.3, and 3.4 on Rails 7.2 and 8.0.2.

## Configuration

### Basic Setup

```ruby
# config/initializers/outbound_http_logger.rb
OutboundHTTPLogger.configure do |config|
  config.enabled = true

  # Optional: Add custom URL exclusions
  config.excluded_urls << %r{/internal-api}

  # Optional: Add custom sensitive headers
  config.sensitive_headers << 'x-custom-token'

  # Optional: Set max body size (default: 10KB)
  config.max_body_size = 50_000

  # Optional: Enable debug logging
  config.debug_logging = Rails.env.development?

  # Optional: Configure secondary database for logging
  config.configure_secondary_database('sqlite3:///log/outbound_requests.sqlite3')
end
```

## Secondary Database Support

The gem supports **optional** logging to a secondary database alongside the main Rails database. This provides **dual logging** - your main database gets all logs, plus an additional specialized database. This is particularly useful for:

- **Local development**: Keep a separate log file for debugging
- **Testing**: Persistent test logs that don't interfere with your main database
- **Analytics**: Separate storage for request analytics and monitoring
- **Performance**: Use optimized databases for logging (e.g., PostgreSQL with JSONB)

### Supported Database Types

- **SQLite** - Perfect for local development and testing
- **PostgreSQL** - High-performance with JSONB support and GIN indexes

### Basic Configuration

```ruby
# config/initializers/outbound_http_logger.rb
OutboundHTTPLogger.configure do |config|
  # Enable logging to your main Rails database (default behavior)
  config.enabled = true

  # That's it! Logs will be stored in your main Rails database using ActiveRecord
  # No additional configuration needed for basic usage
end
```

### Additional Database Configuration (Optional)

If you want to **also** log to a separate database (in addition to your main Rails database):

```ruby
# config/initializers/outbound_http_logger.rb
OutboundHTTPLogger.configure do |config|
  config.enabled = true # Main Rails database logging

  # OPTIONAL: Also log to an additional database

  # SQLite (simple file-based logging)
  config.configure_secondary_database('sqlite3:///log/outbound_requests.sqlite3')

  # PostgreSQL (high-performance with JSONB)
  config.configure_secondary_database('postgresql://user:pass@host/logs_db')

  # Or use environment variable
  config.configure_secondary_database(ENV.fetch('OUTBOUND_LOGGING_DATABASE_URL', nil))
end
```

### Programmatic Control

```ruby
# Main database logging (always uses your Rails database)
OutboundHTTPLogger.enable!   # Enable main database logging
OutboundHTTPLogger.disable!  # Disable all logging
OutboundHTTPLogger.enabled?  # Check if logging is enabled

# Additional database logging (optional, in addition to main database)
OutboundHTTPLogger.enable_secondary_logging!('sqlite3:///log/outbound_requests.sqlite3')
OutboundHTTPLogger.enable_secondary_logging!('postgresql://user:pass@host/logs')
OutboundHTTPLogger.disable_secondary_logging!
OutboundHTTPLogger.secondary_logging_enabled?
```

### Environment-specific Configuration

```ruby
# config/environments/production.rb
OutboundHTTPLogger.configure do |config|
  config.enabled       = true
  config.debug_logging = false
end

# config/environments/development.rb
OutboundHTTPLogger.configure do |config|
  config.enabled       = true
  config.debug_logging = true
end
```

## Usage

Once configured, the gem automatically logs all outbound HTTP requests via patches to Net::HTTP, Faraday, and HTTParty:

```ruby
# All outbound requests will be automatically logged
Net::HTTP.get(URI('https://api.example.com/users'))  # -> logged
HTTParty.get('https://api.example.com/orders')       # -> logged
Faraday.get('https://api.example.com/products')      # -> logged
```

### Model Integration

Associate outbound HTTP requests with your ActiveRecord models:

```ruby
class UsersController < ApplicationController
  include OutboundHTTPLogger::Concerns::OutboundLogging

  def sync_user
    user = User.find(params[:id])

    # Associate all outbound requests in this thread with the user
    set_outbound_log_loggable(user)
    add_outbound_log_metadata(action: 'user_sync', source: 'manual')

    # This request will be associated with the user
    response = HTTParty.post('https://api.example.com/sync',
                             body: user.to_json,
                             headers: { 'Content-Type' => 'application/json' })

    render json: { status: 'synced' }
  end
end
```

#### Thread-local Association

```ruby
# Set loggable for all outbound requests in current thread
OutboundHTTPLogger.set_loggable(current_user)
OutboundHTTPLogger.set_metadata(action: 'bulk_sync', batch_id: 123)

# All subsequent HTTP requests will be associated with current_user
HTTParty.get('https://api.example.com/users')
Faraday.post('https://api.example.com/orders', body: data.to_json)

# Clear thread-local data when done
OutboundHTTPLogger.clear_thread_data
```

#### Scoped Association

```ruby
# Temporarily associate requests with a specific object
OutboundHTTPLogger.with_logging(loggable: order, metadata: { action: 'fulfillment' }) do
  # These requests will be associated with the order
  HTTParty.post('https://shipping.example.com/create', body: order.shipping_data)
  HTTParty.post('https://inventory.example.com/reserve', body: order.items)
end
# Thread-local data is automatically restored after the block
```

### Querying Logs

```ruby
# Find all logs
logs = OutboundHTTPLogger::Models::OutboundRequestLog.all

# Find by status code
error_logs   = OutboundHTTPLogger::Models::OutboundRequestLog.failed
success_logs = OutboundHTTPLogger::Models::OutboundRequestLog.successful

# Find by HTTP method
post_logs = OutboundHTTPLogger::Models::OutboundRequestLog.with_method('POST')

# Find logs associated with a specific model
user_logs = OutboundHTTPLogger::Models::OutboundRequestLog.for_loggable(user)

# Find slow requests (over 1 second by default)
slow_logs = OutboundHTTPLogger::Models::OutboundRequestLog.slow

# Search with multiple criteria
results     = OutboundHTTPLogger::Models::OutboundRequestLog.search(
  q: 'api.example.com',
  status: [200, 201],
  method: 'POST',
  loggable_type: 'User',
  loggable_id: user.id
)
```

### Log Analysis

```ruby
# Get recent logs
recent_logs = OutboundHTTPLogger::Models::OutboundRequestLog.recent.limit(10)

recent_logs.each do |log|
  puts "#{log.http_method} #{log.url} -> #{log.status_code} (#{log.formatted_duration})"
  puts "Associated with: #{log.loggable.class.name}##{log.loggable.id}" if log.loggable
  puts "Metadata: #{log.metadata}" if log.metadata.present?
  puts '---'
end
```

## Test Utilities

The gem provides a dedicated test namespace with powerful utilities for testing outbound HTTP request logging:

### Test Configuration

```ruby
require 'outbound_http_logger/test' # Required for test utilities

# Configure test logging with separate database
OutboundHTTPLogger::Test.configure(
  database_url: 'sqlite3:///tmp/test_outbound_requests.sqlite3',
  adapter: :sqlite
)

# Or use PostgreSQL for tests
OutboundHTTPLogger::Test.configure(
  database_url: 'postgresql://localhost/test_outbound_logs',
  adapter: :postgresql
)

# Enable test logging
OutboundHTTPLogger::Test.enable!

# Disable test logging
OutboundHTTPLogger::Test.disable!
```

### Test Utilities API

```ruby
require 'outbound_http_logger/test' # Required for test utilities

# Count all logged outbound requests during tests
total_requests = OutboundHTTPLogger::Test.logs_count

# Count requests by status code
successful_requests = OutboundHTTPLogger::Test.logs_with_status(200)
error_requests = OutboundHTTPLogger::Test.logs_with_status(500)

# Count requests for specific URLs
api_requests = OutboundHTTPLogger::Test.logs_for_url('api.example.com')
webhook_requests = OutboundHTTPLogger::Test.logs_for_url('webhooks')

# Get all logged requests
all_logs = OutboundHTTPLogger::Test.all_logs

# Get logs matching specific criteria
failed_requests = OutboundHTTPLogger::Test.logs_matching(status: 500)
api_posts = OutboundHTTPLogger::Test.logs_matching(method: 'POST', url: 'api.example.com')

# Analyze request patterns
analysis = OutboundHTTPLogger::Test.analyze
# Returns: { total: 100, successful: 95, failed: 5, success_rate: 95.0, average_duration: 250.5 }

# Clear test logs manually (if needed)
OutboundHTTPLogger::Test.clear_logs!

# Reset test environment
OutboundHTTPLogger::Test.reset!
```

### Test Framework Integration

#### Minitest Setup

```ruby
# test/test_helper.rb
require 'outbound_http_logger/test' # Required for test utilities

module ActiveSupport
  class TestCase
    include OutboundHTTPLogger::Test::Helpers

    setup do
      setup_outbound_http_logger_test(
        database_url: 'sqlite3:///tmp/test_outbound_requests.sqlite3'
      )
    end

    teardown do
      teardown_outbound_http_logger_test
    end
  end
end

# In your tests
class APIIntegrationTest < ActiveSupport::TestCase
  test 'logs outbound API requests correctly' do
    # Stub external API
    stub_request(:post, 'https://api.example.com/users')
      .to_return(status: 201, body: '{"id": 123}')

    # Make outbound request
    HTTParty.post('https://api.example.com/users', body: { name: 'John' }.to_json)

    # Use helper methods
    assert_outbound_request_logged('POST', 'https://api.example.com/users', status: 201)
    assert_outbound_request_count(1)

    # Or use direct API
    assert_equal 1, OutboundHTTPLogger::Test.logs_count
    assert_equal 1, OutboundHTTPLogger::Test.logs_with_status(201).count
  end

  test 'analyzes outbound request patterns' do
    stub_request(:get, 'https://api.example.com/users').to_return(status: 200)
    stub_request(:get, 'https://api.example.com/missing').to_return(status: 404)

    HTTParty.get('https://api.example.com/users')    # 200
    HTTParty.get('https://api.example.com/missing')  # 404

    analysis = OutboundHTTPLogger::Test.analyze
    assert_equal 2, analysis[:total]
    assert_equal 50.0, analysis[:success_rate]
    assert_outbound_success_rate(50.0, tolerance: 0.1)
  end
end
```

#### RSpec Setup

```ruby
# spec/rails_helper.rb
require 'outbound_http_logger/test' # Required for test utilities

RSpec.configure do |config|
  config.include OutboundHTTPLogger::Test::Helpers

  config.before(:each) do
    setup_outbound_http_logger_test
  end

  config.after(:each) do
    teardown_outbound_http_logger_test
  end
end

# In your specs
RSpec.describe 'Outbound API logging' do
  it 'logs requests correctly' do
    stub_request(:get, 'https://api.example.com/users')
      .to_return(status: 200, body: '[]')

    HTTParty.get('https://api.example.com/users')

    expect(OutboundHTTPLogger::Test.logs_count).to eq(1)
    assert_outbound_request_logged('GET', 'https://api.example.com/users')
    assert_outbound_success_rate(100.0)
  end
end
```

### Parallel Testing Support

The gem is fully thread-safe and supports parallel testing frameworks. It uses thread-local variables for request-specific metadata and loggable associations, ensuring that concurrent requests and tests don't interfere with each other.

#### Thread-Safe Configuration

For parallel testing frameworks, use the thread-safe configuration override:

```ruby
# Thread-safe configuration changes for testing
OutboundHTTPLogger.with_configuration(enabled: true, debug_logging: true) do
  # Configuration changes only affect current thread
  # Other test threads are unaffected
  # Automatically restored when block exits
end
```

#### Configuration Backup and Restore

For advanced test scenarios, you can manually backup and restore configuration:

```ruby
# Backup current configuration
backup = OutboundHTTPLogger::Test.backup_configuration

# Make changes
OutboundHTTPLogger.configure do |config|
  config.enabled = false
  config.excluded_urls << 'https://skip-this.com'
end

# Restore original configuration
OutboundHTTPLogger::Test.restore_configuration(backup)

# Or use the helper method for isolated configuration changes
OutboundHTTPLogger::Test.with_configuration(enabled: false) do
  # Configuration changes are automatically restored after block
  # This is the recommended approach for most test scenarios
end
```

#### Test Helper Integration

```ruby
describe 'My Feature' do
  include OutboundHTTPLogger::Test::Helpers

  it 'logs requests with thread-safe configuration' do
    # Uses the simplified thread-safe configuration system
    with_thread_safe_configuration(enabled: true, debug_logging: true) do
      # Configuration changes only affect current thread
      # Safe for parallel test execution
      HTTParty.get('https://api.example.com/data')
      assert_outbound_request_logged('GET', 'https://api.example.com/data')
    end
    # Configuration automatically restored after block
  end
end
```

#### Parallel Test Example

```ruby
# Multiple tests can run simultaneously without interference
RSpec.describe 'Parallel API tests', parallel: true do
  it 'test 1 with custom config' do
    with_thread_safe_configuration(max_body_size: 5000, debug_logging: true) do
      # This configuration only affects this test thread
      HTTParty.post('https://api.example.com/large-data', body: large_payload)
      expect(OutboundHTTPLogger::Test.logs_count).to eq(1)
    end
  end

  it 'test 2 with different config' do
    with_thread_safe_configuration(max_body_size: 1000, debug_logging: false) do
      # This configuration is isolated from test 1
      HTTParty.get('https://api.example.com/small-data')
      expect(OutboundHTTPLogger::Test.logs_count).to eq(1)
    end
  end
end
```

## Advanced Configuration

### Custom Exclusions

```ruby
OutboundHTTPLogger.configure do |config|
  # Exclude specific URL patterns
  config.excluded_urls << %r{/webhooks}
  config.excluded_urls << /\.amazonaws\.com/

  # Exclude specific content types
  config.excluded_content_types << 'application/pdf'
  config.excluded_content_types << 'image/*'

  # Add custom sensitive headers
  config.sensitive_headers << 'x-api-secret'
  config.sensitive_headers << 'x-webhook-signature'
end
```

### Performance Tuning

```ruby
OutboundHTTPLogger.configure do |config|
  # Increase body size limit for APIs that return large responses
  config.max_body_size = 100_000 # 100KB

  # Enable debug logging only in development
  config.debug_logging = Rails.env.development?
end
```

## Database Features and Optimizations

### Database Adapters

The gem includes specialized database adapters that leverage database-specific features for optimal performance:

#### PostgreSQL Adapter
- **JSONB columns**: Native JSON storage with indexing support
- **GIN indexes**: Fast JSON queries and text search
- **Trigram search**: Full-text search on URLs using pg_trgm extension
- **Advanced queries**: Native JSONB operators for complex filtering

```ruby
# PostgreSQL-specific queries
OutboundHTTPLogger::Models::OutboundRequestLog.with_response_containing('status', 'success')
OutboundHTTPLogger::Models::OutboundRequestLog.with_request_header('Authorization', 'Bearer token')
OutboundHTTPLogger::Models::OutboundRequestLog.with_metadata_containing('user_id', 123)
```

#### SQLite Adapter
- **JSON columns**: Native JSON support in SQLite 3.38+
- **JSON functions**: Uses SQLite's JSON_EXTRACT for queries
- **Optimized indexes**: Appropriate indexes for common query patterns

```ruby
# SQLite-specific queries (same API as PostgreSQL)
OutboundHTTPLogger::Models::OutboundRequestLog.with_response_containing('error_code', '404')
OutboundHTTPLogger::Models::OutboundRequestLog.with_request_header('Content-Type', 'application/json')
```

### Migration Features

The gem provides rollback-capable migrations with database-specific optimizations:

```ruby
# The migration automatically detects your database and optimizes accordingly
rails generate outbound_http_logger: migration
rails db: migrate

# Rollback support
rails db: rollback
```

**Migration Features:**
- **Rollback support**: Proper `up` and `down` methods
- **Database detection**: Automatically uses JSONB for PostgreSQL, JSON for others
- **Optimized indexes**: Essential indexes only, avoiding over-indexing for append-only logs
- **Extension management**: Automatically enables pg_trgm for PostgreSQL text search

## Performance Considerations and Best Practices

### Performance Optimizations

The gem is designed for minimal performance impact on your application:

- **Early exit guards**: Logging checks are performed before any expensive operations
- **Deferred processing**: URL and content type filtering happens before request capture
- **Optimized serialization**: Direct JSON storage without intermediate string conversions
- **Minimal database overhead**: Only essential indexes for append-only logging patterns
- **Connection pooling**: Leverages Rails' native database connection management
- **Thread-safe design**: Proper thread-local variable management prevents contention

### Performance Impact

**Typical overhead per HTTP request:**
- **Enabled logging**: ~0.5-2ms additional latency
- **Disabled logging**: ~0.01ms (single boolean check)
- **Excluded URLs**: ~0.1ms (regex matching only)
- **Memory usage**: ~1-5KB per logged request (depending on body size)

### Best Practices for Production

#### 1. Configure Appropriate Exclusions

```ruby
OutboundHTTPLogger.configure do |config|
  # Exclude high-frequency, low-value requests
  config.excluded_urls = [
    %r{/health},                    # Health checks
    %r{/metrics},                   # Monitoring endpoints
    %r{/ping},                      # Ping endpoints
    %r{\.amazonaws\.com/.*\.css},   # Static assets
    %r{\.cloudfront\.net},          # CDN requests
    %r{analytics\.google\.com}      # Analytics tracking
  ]

  # Exclude binary and static content
  config.excluded_content_types = [
    'image/',                       # All image types
    'video/',                       # All video types
    'audio/',                       # All audio types
    'application/pdf',              # PDF files
    'application/zip',              # Archive files
    'text/css',                     # Stylesheets
    'text/javascript',              # JavaScript files
    'application/javascript'        # JavaScript files
  ]
end
```

#### 2. Limit Body Size for Large Payloads

```ruby
OutboundHTTPLogger.configure do |config|
  # Limit body size to prevent memory issues with large payloads
  config.max_body_size = 10_000  # 10KB (default)
  # For APIs with large responses, consider smaller limits:
  # config.max_body_size = 5_000   # 5KB for high-traffic APIs
end
```

#### 3. Use Secondary Database for High-Volume Applications

```ruby
# Separate logging database to avoid impacting main application performance
OutboundHTTPLogger.enable_secondary_logging!(
  'postgresql://localhost/outbound_logs_production',
  adapter: :postgresql
)
```

#### 4. Implement Log Rotation and Cleanup

```ruby
# Add to a scheduled job (e.g., sidekiq-cron, whenever gem)
class OutboundLogCleanupJob
  def perform
    # Keep only last 30 days of logs
    cutoff_date = 30.days.ago
    OutboundHTTPLogger::Models::OutboundRequestLog
      .where('created_at < ?', cutoff_date)
      .delete_all
  end
end
```

### Monitoring and Observability

#### 1. Monitor Log Volume

```ruby
# Check log growth rate
recent_logs = OutboundHTTPLogger::Models::OutboundRequestLog
  .where('created_at > ?', 1.hour.ago)
  .count

puts "Logs per hour: #{recent_logs}"
```

#### 2. Identify High-Volume Endpoints

```ruby
# Find most frequently logged URLs
OutboundHTTPLogger::Models::OutboundRequestLog
  .group(:url)
  .order('count_all DESC')
  .limit(10)
  .count
```

#### 3. Monitor Performance Impact

```ruby
# Check average request duration
avg_duration = OutboundHTTPLogger::Models::OutboundRequestLog
  .where('created_at > ?', 1.day.ago)
  .average(:duration_seconds)

puts "Average request duration: #{avg_duration}s"
```

### Scaling Considerations

#### For High-Traffic Applications (>1000 requests/minute)

1. **Use dedicated database**: Separate logging database prevents impact on main application
2. **Implement async logging**: Consider background job processing for logging
3. **Aggressive filtering**: Exclude more URL patterns and content types
4. **Regular cleanup**: Automated log rotation and archival

#### For Memory-Constrained Environments

1. **Reduce body size limits**: Lower `max_body_size` to 1-2KB
2. **Exclude large responses**: Filter out content types with large payloads
3. **Limit metadata**: Minimize custom metadata to essential information only

#### Database Optimization

```sql
-- PostgreSQL: Optimize for time-series queries
CREATE INDEX CONCURRENTLY idx_outbound_logs_created_at_desc
ON outbound_request_logs (created_at DESC);

-- PostgreSQL: Optimize for URL pattern searches
CREATE INDEX CONCURRENTLY idx_outbound_logs_url_gin
ON outbound_request_logs USING gin (url gin_trgm_ops);

-- Regular maintenance
VACUUM ANALYZE outbound_request_logs;
```

### Troubleshooting Performance Issues

#### 1. High Memory Usage

- Check `max_body_size` configuration
- Review excluded content types
- Monitor for memory leaks in long-running processes

#### 2. Database Performance

- Ensure proper indexing on `created_at` column
- Implement regular log cleanup
- Consider partitioning for very high-volume applications

#### 3. Request Latency

- Review excluded URL patterns
- Check for recursive logging (should be prevented automatically)
- Monitor database connection pool usage

### ActiveRecord Integration

- **Native ActiveRecord**: All database operations use ActiveRecord models and migrations
- **Rails-native**: Integrates seamlessly with your existing Rails database setup
- **Default connection**: Uses your main Rails database connection by default
- **Multiple database support**: Secondary databases use Rails' connection management
- **Migration support**: Includes Rails generator for creating the required database table

## Thread Safety

The gem is fully thread-safe and uses thread-local variables for request-specific metadata and loggable associations. Each thread maintains its own context, so concurrent requests won't interfere with each other.

## Error Handling

All logging operations are wrapped in failsafe error handling. If logging fails for any reason, the original HTTP request continues normally and the error is logged to Rails.logger.

## Development

### Local Development

```bash
bundle install
bundle exec rake test
```


### Git Hooks

Use the provided `pre-commit` hook to run RuboCop before each commit:

```bash
# we use RVM inhouse, so we assume that. Adjust as you see fit (or skip hooks, the same checks happen in CI anyway)
git config core.hooksPath githooks
```

#### Testing Against Multiple Databases

The gem supports testing against both SQLite and PostgreSQL databases. By default, tests run against an in-memory SQLite database.

**SQLite Testing (default):**
```bash
bundle exec rake test
# or
DATABASE_ADAPTER=sqlite3 bundle exec rake test
```

**PostgreSQL Testing:**

1. Set up a PostgreSQL database:
```bash
createdb outbound_http_logger_test
```

2. Create a `.env.test` file (copy from `.env.test.example`):
```bash
cp .env.test.example .env.test
```

3. Configure your `.env.test` file:
```bash
DATABASE_ADAPTER=postgresql
DATABASE_URL=postgresql://postgres:@localhost:5432/outbound_http_logger_test
```

4. Run tests:
```bash
bundle exec rake test
# or explicitly
DATABASE_ADAPTER=postgresql bundle exec rake test
```

**Testing Both Databases:**
```bash
# Test SQLite first
DATABASE_ADAPTER=sqlite3 bundle exec rake test

# Then test PostgreSQL
DATABASE_ADAPTER=postgresql bundle exec rake test

# Or use the convenience script to test both automatically
./bin/test-databases
```

### Running CI Checks Locally

Use the provided CI script to run all checks locally:

```bash
./bin/ci
```

This script runs:
- Tests with Minitest (SQLite by default)
- RuboCop linting
- Gem building and validation
- Security audit with bundler-audit
- TODO/FIXME comment detection

**Testing with PostgreSQL in CI script:**
```bash
# Set environment variable to test PostgreSQL as well
TEST_POSTGRESQL=1 ./bin/ci

# Or with custom database URL
DATABASE_URL=postgresql://user:pass@localhost/test_db ./bin/ci
```

### Continuous Integration

The gem includes GitHub Actions workflows that automatically run on:
- Push to `develop` or `main` branches (when gem files change)
- Pull requests targeting `develop` or `main` branches (when gem files change)

The CI pipeline includes:
- **Test Job**: Runs tests against Ruby 3.2, 3.3, and 3.4 on Rails 7.2 and 8.0.2 with both SQLite and PostgreSQL databases
- **Build Job**: Validates gem can be built successfully
- **Quality Job**: Runs RuboCop linting and validates gemspec
- **Security Job**: Runs bundler-audit for dependency vulnerabilities

### Code Quality

The gem follows the project's RuboCop configuration with gem-specific overrides:
- Documentation is required for public APIs
- Test files are excluded from documentation requirements
- Line length limits are relaxed for test files

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

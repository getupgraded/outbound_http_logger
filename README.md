# OutboundHttpLogger

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
gem 'outbound_http_logger', git: "https://github.com/getupgraded/outbound_http_logger.git" # this is not a published gem yet
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
OutboundHttpLogger.configure do |config|
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
OutboundHttpLogger.configure do |config|
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
OutboundHttpLogger.configure do |config|
  config.enabled = true  # Main Rails database logging

  # OPTIONAL: Also log to an additional database

  # SQLite (simple file-based logging)
  config.configure_secondary_database('sqlite3:///log/outbound_requests.sqlite3')

  # PostgreSQL (high-performance with JSONB)
  config.configure_secondary_database('postgresql://user:pass@host/logs_db')

  # Or use environment variable
  config.configure_secondary_database(ENV['OUTBOUND_LOGGING_DATABASE_URL'])
end
```

### Programmatic Control

```ruby
# Main database logging (always uses your Rails database)
OutboundHttpLogger.enable!   # Enable main database logging
OutboundHttpLogger.disable!  # Disable all logging
OutboundHttpLogger.enabled?  # Check if logging is enabled

# Additional database logging (optional, in addition to main database)
OutboundHttpLogger.enable_secondary_logging!('sqlite3:///log/outbound_requests.sqlite3')
OutboundHttpLogger.enable_secondary_logging!('postgresql://user:pass@host/logs')
OutboundHttpLogger.disable_secondary_logging!
OutboundHttpLogger.secondary_logging_enabled?
```

### Environment-specific Configuration

```ruby
# config/environments/production.rb
OutboundHttpLogger.configure do |config|
  config.enabled       = true
  config.debug_logging = false
end

# config/environments/development.rb
OutboundHttpLogger.configure do |config|
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
  include OutboundHttpLogger::Concerns::OutboundLogging

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
OutboundHttpLogger.set_loggable(current_user)
OutboundHttpLogger.set_metadata(action: 'bulk_sync', batch_id: 123)

# All subsequent HTTP requests will be associated with current_user
HTTParty.get('https://api.example.com/users')
Faraday.post('https://api.example.com/orders', body: data.to_json)

# Clear thread-local data when done
OutboundHttpLogger.clear_thread_data
```

#### Scoped Association

```ruby
# Temporarily associate requests with a specific object
OutboundHttpLogger.with_logging(loggable: order, metadata: { action: 'fulfillment' }) do
  # These requests will be associated with the order
  HTTParty.post('https://shipping.example.com/create', body: order.shipping_data)
  HTTParty.post('https://inventory.example.com/reserve', body: order.items)
end
# Thread-local data is automatically restored after the block
```

### Querying Logs

```ruby
# Find all logs
logs = OutboundHttpLogger::Models::OutboundRequestLog.all

# Find by status code
error_logs   = OutboundHttpLogger::Models::OutboundRequestLog.failed
success_logs = OutboundHttpLogger::Models::OutboundRequestLog.successful

# Find by HTTP method
post_logs = OutboundHttpLogger::Models::OutboundRequestLog.with_method('POST')

# Find logs associated with a specific model
user_logs = OutboundHttpLogger::Models::OutboundRequestLog.for_loggable(user)

# Find slow requests (over 1 second by default)
slow_logs = OutboundHttpLogger::Models::OutboundRequestLog.slow

# Search with multiple criteria
results     = OutboundHttpLogger::Models::OutboundRequestLog.search(
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
recent_logs = OutboundHttpLogger::Models::OutboundRequestLog.recent.limit(10)

recent_logs.each do |log|
  puts "#{log.http_method} #{log.url} -> #{log.status_code} (#{log.formatted_duration})"
  puts "Associated with: #{log.loggable.class.name}##{log.loggable.id}" if log.loggable
  puts "Metadata: #{log.metadata}" if log.metadata.present?
  puts "---"
end
```

## Test Utilities

The gem provides a dedicated test namespace with powerful utilities for testing outbound HTTP request logging:

### Test Configuration

```ruby
require 'outbound_http_logger/test'  # Required for test utilities

# Configure test logging with separate database
OutboundHttpLogger::Test.configure(
  database_url: 'sqlite3:///tmp/test_outbound_requests.sqlite3',
  adapter: :sqlite
)

# Or use PostgreSQL for tests
OutboundHttpLogger::Test.configure(
  database_url: 'postgresql://localhost/test_outbound_logs',
  adapter: :postgresql
)

# Enable test logging
OutboundHttpLogger::Test.enable!

# Disable test logging
OutboundHttpLogger::Test.disable!
```

### Test Utilities API

```ruby
require 'outbound_http_logger/test'  # Required for test utilities

# Count all logged outbound requests during tests
total_requests = OutboundHttpLogger::Test.logs_count

# Count requests by status code
successful_requests = OutboundHttpLogger::Test.logs_with_status(200)
error_requests = OutboundHttpLogger::Test.logs_with_status(500)

# Count requests for specific URLs
api_requests = OutboundHttpLogger::Test.logs_for_url('api.example.com')
webhook_requests = OutboundHttpLogger::Test.logs_for_url('webhooks')

# Get all logged requests
all_logs = OutboundHttpLogger::Test.all_logs

# Get logs matching specific criteria
failed_requests = OutboundHttpLogger::Test.logs_matching(status: 500)
api_posts = OutboundHttpLogger::Test.logs_matching(method: 'POST', url: 'api.example.com')

# Analyze request patterns
analysis = OutboundHttpLogger::Test.analyze
# Returns: { total: 100, successful: 95, failed: 5, success_rate: 95.0, average_duration: 250.5 }

# Clear test logs manually (if needed)
OutboundHttpLogger::Test.clear_logs!

# Reset test environment
OutboundHttpLogger::Test.reset!
```

### Test Framework Integration

#### Minitest Setup

```ruby
# test/test_helper.rb
require 'outbound_http_logger/test'  # Required for test utilities

class ActiveSupport::TestCase
  include OutboundHttpLogger::Test::Helpers

  setup do
    setup_outbound_http_logger_test(
      database_url: 'sqlite3:///tmp/test_outbound_requests.sqlite3'
    )
  end

  teardown do
    teardown_outbound_http_logger_test
  end
end

# In your tests
class APIIntegrationTest < ActiveSupport::TestCase
  test "logs outbound API requests correctly" do
    # Stub external API
    stub_request(:post, "https://api.example.com/users")
      .to_return(status: 201, body: '{"id": 123}')

    # Make outbound request
    HTTParty.post('https://api.example.com/users', body: { name: 'John' }.to_json)

    # Use helper methods
    assert_outbound_request_logged('POST', 'https://api.example.com/users', status: 201)
    assert_outbound_request_count(1)

    # Or use direct API
    assert_equal 1, OutboundHttpLogger::Test.logs_count
    assert_equal 1, OutboundHttpLogger::Test.logs_with_status(201).count
  end

  test "analyzes outbound request patterns" do
    stub_request(:get, "https://api.example.com/users").to_return(status: 200)
    stub_request(:get, "https://api.example.com/missing").to_return(status: 404)

    HTTParty.get('https://api.example.com/users')    # 200
    HTTParty.get('https://api.example.com/missing')  # 404

    analysis = OutboundHttpLogger::Test.analyze
    assert_equal 2, analysis[:total]
    assert_equal 50.0, analysis[:success_rate]
    assert_outbound_success_rate(50.0, tolerance: 0.1)
  end
end
```

#### RSpec Setup

```ruby
# spec/rails_helper.rb
require 'outbound_http_logger/test'  # Required for test utilities

RSpec.configure do |config|
  config.include OutboundHttpLogger::Test::Helpers

  config.before(:each) do
    setup_outbound_http_logger_test
  end

  config.after(:each) do
    teardown_outbound_http_logger_test
  end
end

# In your specs
RSpec.describe "Outbound API logging" do
  it "logs requests correctly" do
    stub_request(:get, "https://api.example.com/users")
      .to_return(status: 200, body: '[]')

    HTTParty.get('https://api.example.com/users')

    expect(OutboundHttpLogger::Test.logs_count).to eq(1)
    assert_outbound_request_logged('GET', 'https://api.example.com/users')
    assert_outbound_success_rate(100.0)
  end
end
```

## Advanced Configuration

### Custom Exclusions

```ruby
OutboundHttpLogger.configure do |config|
  # Exclude specific URL patterns
  config.excluded_urls << %r{/webhooks}
  config.excluded_urls << %r{\.amazonaws\.com}

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
OutboundHttpLogger.configure do |config|
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
OutboundHttpLogger::Models::OutboundRequestLog.with_response_containing('status', 'success')
OutboundHttpLogger::Models::OutboundRequestLog.with_request_header('Authorization', 'Bearer token')
OutboundHttpLogger::Models::OutboundRequestLog.with_metadata_containing('user_id', 123)
```

#### SQLite Adapter
- **JSON columns**: Native JSON support in SQLite 3.38+
- **JSON functions**: Uses SQLite's JSON_EXTRACT for queries
- **Optimized indexes**: Appropriate indexes for common query patterns

```ruby
# SQLite-specific queries (same API as PostgreSQL)
OutboundHttpLogger::Models::OutboundRequestLog.with_response_containing('error_code', '404')
OutboundHttpLogger::Models::OutboundRequestLog.with_request_header('Content-Type', 'application/json')
```

### Migration Features

The gem provides rollback-capable migrations with database-specific optimizations:

```ruby
# The migration automatically detects your database and optimizes accordingly
rails generate outbound_http_logger:migration
rails db:migrate

# Rollback support
rails db:rollback
```

**Migration Features:**
- **Rollback support**: Proper `up` and `down` methods
- **Database detection**: Automatically uses JSONB for PostgreSQL, JSON for others
- **Optimized indexes**: Essential indexes only, avoiding over-indexing for append-only logs
- **Extension management**: Automatically enables pg_trgm for PostgreSQL text search

### Performance Optimizations

- **Deferred calls**: Early exit guards prevent unnecessary processing
- **Optimized serialization**: Direct JSON storage without string conversions
- **Minimal indexes**: Only essential indexes for append-only logging patterns
- **Connection pooling**: Uses Rails' native database connection management
- **Thread-safe**: Proper thread-local variable management

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

### Running CI Checks Locally

Use the provided CI script to run all checks locally:

```bash
./bin/ci
```

This script runs:
- Tests with Minitest
- RuboCop linting
- Gem building and validation
- Security audit with bundler-audit
- TODO/FIXME comment detection

### Continuous Integration

The gem includes GitHub Actions workflows that automatically run on:
- Push to `develop` or `main` branches (when gem files change)
- Pull requests targeting `develop` or `main` branches (when gem files change)

The CI pipeline includes:
- **Test Job**: Runs tests against Ruby 3.2, 3.3, and 3.4 on Rails 7.2 and 8.0.2
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

# OutboundHttpLogger

[![CI](https://github.com/getupgraded/outbound_http_logger/actions/workflows/test.yml/badge.svg)](https://github.com/getupgraded/outbound_http_logger/actions/workflows/outbound-http-logger-ci.yml)

A production-safe gem for comprehensive outbound HTTP request logging in Rails applications. Supports multiple HTTP libraries with configurable filtering and failsafe error handling.

## Features

- **Multi-library support**: Net::HTTP, Faraday, HTTParty
- **Comprehensive logging**: Request/response headers, bodies, timing, status codes
- **Security-first**: Automatic filtering of sensitive headers and body data
- **Performance-optimized**: Early-exit logic when disabled, minimal overhead
- **Production-safe**: Failsafe error handling ensures HTTP requests never fail due to logging
- **Configurable exclusions**: URL patterns, content types, and custom filters
- **Database agnostic**: Works with PostgreSQL (JSONB) and SQLite (JSON)
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
end
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
- **Test Job**: Runs tests against Ruby 3.4 and Rails 7.2
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

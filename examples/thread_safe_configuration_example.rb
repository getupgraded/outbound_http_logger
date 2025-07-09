#!/usr/bin/env ruby
# frozen_string_literal: true

# Example demonstrating thread-safe configuration for parallel testing
require_relative '../lib/outbound_http_logger'

puts "=== Thread-Safe Configuration Example ==="
puts

# Set up initial configuration
OutboundHTTPLogger.configure do |config|
  config.enabled = false
  config.debug_logging = false
  config.max_body_size = 10_000
end

puts "Initial configuration:"
puts "  enabled: #{OutboundHTTPLogger.configuration.enabled?}"
puts "  debug_logging: #{OutboundHTTPLogger.configuration.debug_logging}"
puts "  max_body_size: #{OutboundHTTPLogger.configuration.max_body_size}"
puts

# Demonstrate thread-safe configuration overrides
puts "=== Thread-Safe Configuration Overrides ==="
puts

results = []
threads = 3.times.map do |i|
  Thread.new do
    # Each thread gets its own configuration context
    OutboundHTTPLogger.with_configuration(
      enabled: i.even?,
      debug_logging: i.odd?,
      max_body_size: 1000 * (i + 1)
    ) do
      sleep 0.1 # Simulate some work and allow potential interference

      results[i] = {
        thread_id: i,
        enabled: OutboundHTTPLogger.configuration.enabled?,
        debug_logging: OutboundHTTPLogger.configuration.debug_logging,
        max_body_size: OutboundHTTPLogger.configuration.max_body_size
      }

      puts "Thread #{i} configuration:"
      puts "  enabled: #{results[i][:enabled]}"
      puts "  debug_logging: #{results[i][:debug_logging]}"
      puts "  max_body_size: #{results[i][:max_body_size]}"
    end
  end
end

threads.each(&:join)

puts
puts "=== Results Summary ==="
results.each_with_index do |result, i|
  puts "Thread #{i}: enabled=#{result[:enabled]}, debug=#{result[:debug_logging]}, max_body=#{result[:max_body_size]}"
end

puts
puts "Final configuration (should be restored to original):"
puts "  enabled: #{OutboundHTTPLogger.configuration.enabled?}"
puts "  debug_logging: #{OutboundHTTPLogger.configuration.debug_logging}"
puts "  max_body_size: #{OutboundHTTPLogger.configuration.max_body_size}"

puts
puts "=== Nested Configuration Example ==="
puts

OutboundHTTPLogger.with_configuration(enabled: true, debug_logging: false) do
  puts "Outer override - enabled: #{OutboundHTTPLogger.configuration.enabled?}, debug: #{OutboundHTTPLogger.configuration.debug_logging}"

  OutboundHTTPLogger.with_configuration(debug_logging: true, max_body_size: 5000) do
    puts "Inner override - enabled: #{OutboundHTTPLogger.configuration.enabled?}, debug: #{OutboundHTTPLogger.configuration.debug_logging}, max_body: #{OutboundHTTPLogger.configuration.max_body_size}"
  end

  puts "Back to outer - enabled: #{OutboundHTTPLogger.configuration.enabled?}, debug: #{OutboundHTTPLogger.configuration.debug_logging}, max_body: #{OutboundHTTPLogger.configuration.max_body_size}"
end

puts "Back to original - enabled: #{OutboundHTTPLogger.configuration.enabled?}, debug: #{OutboundHTTPLogger.configuration.debug_logging}, max_body: #{OutboundHTTPLogger.configuration.max_body_size}"

puts
puts "=== Exception Safety Example ==="
puts

begin
  OutboundHTTPLogger.with_configuration(enabled: true) do
    puts "Inside override - enabled: #{OutboundHTTPLogger.configuration.enabled?}"
    raise StandardError, "Simulated error"
  end
rescue StandardError => e
  puts "Caught exception: #{e.message}"
end

puts "After exception - enabled: #{OutboundHTTPLogger.configuration.enabled?} (should be restored)"

puts
puts "=== Parallel Testing Pattern ==="
puts

# Simulate parallel test execution
test_results = []
test_threads = 2.times.map do |test_id|
  Thread.new do
    # Each test gets isolated configuration
    OutboundHTTPLogger.with_configuration(
      enabled: true,
      debug_logging: test_id.even?,
      excluded_urls: ["/test#{test_id}"]
    ) do
      # Simulate test work
      sleep 0.05

      test_results[test_id] = {
        test_id: test_id,
        config_isolated: OutboundHTTPLogger.configuration.excluded_urls.include?("/test#{test_id}"),
        debug_setting: OutboundHTTPLogger.configuration.debug_logging
      }
    end
  end
end

test_threads.each(&:join)

puts "Test isolation results:"
test_results.each do |result|
  puts "  Test #{result[:test_id]}: isolated=#{result[:config_isolated]}, debug=#{result[:debug_setting]}"
end

puts
puts "=== Example Complete ==="

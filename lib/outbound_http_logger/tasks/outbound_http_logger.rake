# frozen_string_literal: true

namespace :outbound_http_logger do
  desc "Analyze outbound HTTP request logs"
  task analyze: :environment do
    require 'outbound_http_logger'

    logs        = OutboundHttpLogger::Models::OutboundRequestLog.all
    total_count = logs.count

    puts "=== OutboundHttpLogger Analysis ==="
    puts
    puts "Total outbound request logs: #{total_count}"

    if total_count == 0
      puts "No outbound request logs found."
      next
    end

    puts
    puts "=== Status Code Breakdown ==="
    status_counts = logs.group(:status_code).count.sort
    status_counts.each do |status, count|
      percentage  = (count.to_f / total_count * 100).round(1)
      status_name = case status
                   when 200..299 then "Success"
                   when 300..399 then "Redirect"
                   when 400..499 then "Client Error"
                   when 500..599 then "Server Error"
                   else "Unknown"
                   end
      puts "  #{status} (#{status_name}): #{count} (#{percentage}%)"
    end

    puts
    puts "=== HTTP Method Breakdown ==="
    method_counts = logs.group(:http_method).count.sort
    method_counts.each do |method, count|
      percentage = (count.to_f / total_count * 100).round(1)
      puts "  #{method}: #{count} (#{percentage}%)"
    end

    puts
    puts "=== Most Frequent URLs (Top 10) ==="
    url_counts = logs.group(:url).count.sort_by { |_, count| -count }.first(10)
    url_counts.each do |url, count|
      percentage  = (count.to_f / total_count * 100).round(1)
      # Truncate long URLs
      display_url = url.length > 80 ? "#{url[0..77]}..." : url
      puts "  #{display_url}: #{count} (#{percentage}%)"
    end

    puts
    puts "=== Performance Metrics ==="
    durations = logs.pluck(:duration_ms).compact
    if durations.any?
      avg_duration = durations.sum / durations.size
      max_duration = durations.max
      slow_count   = logs.where('duration_ms > ?', 1000).count
      puts "  Average response time: #{avg_duration.round(2)}ms"
      puts "  Maximum response time: #{max_duration}ms"
      puts "  Slow requests (>1s): #{slow_count} (#{(slow_count.to_f / total_count * 100).round(1)}%)"
    else
      puts "  No duration data available"
    end

    puts
    puts "=== Recent Activity (Last 10) ==="
    recent_logs = logs.order(created_at: :desc).limit(10)
    recent_logs.each do |log|
      duration_str = log.duration_ms ? " (#{log.formatted_duration})" : ""
      url_display  = log.url.length > 60 ? "#{log.url[0..57]}..." : log.url
      puts "  #{log.created_at.strftime('%Y-%m-%d %H:%M:%S')} - #{log.http_method} #{url_display} - #{log.status_code}#{duration_str}"
    end

    puts
    puts "=== Error Analysis ==="
    failed_logs  = logs.where('status_code >= ?', 400)
    failed_count = failed_logs.count
    if failed_count > 0
      puts "  Total failed requests: #{failed_count} (#{(failed_count.to_f / total_count * 100).round(1)}%)"
      puts "  Top error URLs:"
      error_url_counts = failed_logs.group(:url).count.sort_by { |_, count| -count }.first(5)
      error_url_counts.each do |url, count|
        display_url = url.length > 60 ? "#{url[0..57]}..." : url
        puts "    #{display_url}: #{count} errors"
      end
    else
      puts "  No failed requests found"
    end

    puts
    puts "=== Configuration Status ==="
    puts "  Enabled: #{OutboundHttpLogger.enabled?}"
    puts "  Debug logging: #{OutboundHttpLogger.configuration.debug_logging}"
    puts "  Max body size: #{OutboundHttpLogger.configuration.max_body_size} bytes"
    puts "  Excluded URLs: #{OutboundHttpLogger.configuration.excluded_urls.size} patterns"
    puts "  Sensitive headers: #{OutboundHttpLogger.configuration.sensitive_headers.size} headers"
    puts
  end

  desc "Clean up old outbound request logs"
  task :cleanup, [:days] => :environment do |t, args|
    require 'outbound_http_logger'

    days        = (args[:days] || 90).to_i
    cutoff_date = days.days.ago

    puts "Cleaning up outbound request logs older than #{days} days (before #{cutoff_date.strftime('%Y-%m-%d %H:%M:%S')})..."

    deleted_count = OutboundHttpLogger::Models::OutboundRequestLog.where('created_at < ?', cutoff_date).delete_all

    puts "Deleted #{deleted_count} old outbound request logs."
  end

  desc "Show recent failed outbound requests"
  task failed: :environment do
    require 'outbound_http_logger'

    failed_logs = OutboundHttpLogger::Models::OutboundRequestLog
                    .where('status_code >= ?', 400)
                    .order(created_at: :desc)
                    .limit(20)

    puts "=== Recent Failed Outbound Requests ==="
    puts

    if failed_logs.empty?
      puts "No failed outbound requests found."
    else
      failed_logs.each do |log|
        duration_str = log.duration_ms ? " (#{log.formatted_duration})" : ""
        url_display  = log.url.length > 80 ? "#{log.url[0..77]}..." : log.url
        puts "#{log.created_at.strftime('%Y-%m-%d %H:%M:%S')} - #{log.http_method} #{url_display} - #{log.status_code}#{duration_str}"
      end
    end
    puts
  end

  desc "Show slow outbound requests"
  task :slow, [:threshold] => :environment do |t, args|
    require 'outbound_http_logger'

    threshold = (args[:threshold] || 1000).to_i

    slow_logs = OutboundHttpLogger::Models::OutboundRequestLog
                  .where('duration_ms > ?', threshold)
                  .order(duration_ms: :desc)
                  .limit(20)

    puts "=== Slow Outbound Requests (> #{threshold}ms) ==="
    puts

    if slow_logs.empty?
      puts "No slow outbound requests found."
    else
      slow_logs.each do |log|
        url_display = log.url.length > 80 ? "#{log.url[0..77]}..." : log.url
        puts "#{log.created_at.strftime('%Y-%m-%d %H:%M:%S')} - #{log.http_method} #{url_display} - #{log.status_code} (#{log.formatted_duration})"
      end
    end
    puts
  end
end

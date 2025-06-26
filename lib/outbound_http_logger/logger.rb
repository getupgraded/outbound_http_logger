# frozen_string_literal: true

module OutboundHttpLogger
  class Logger
    attr_reader :configuration

    def initialize(configuration)
      @configuration = configuration
    end

    # Log an outbound HTTP request with timing
    def log_request(method, url, request_data = {})
      return yield if block_given? && !configuration.enabled?
      return yield if block_given? && !configuration.should_log_url?(url)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        # Execute the HTTP request
        response = yield if block_given?

        # Calculate duration
        end_time         = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration_seconds = end_time - start_time

        # Extract response data
        response_data = extract_response_data(response)

        # Log the request
        Models::OutboundRequestLog.log_request(
          method,
          url,
          request_data,
          response_data,
          duration_seconds
        )

        response
      rescue StandardError => e
        # Calculate duration even for failed requests
        end_time         = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration_seconds = end_time - start_time

        # Log the failed request
        Models::OutboundRequestLog.log_request(
          method,
          url,
          request_data,
          { status_code: 0, headers: {}, body: "Error: #{e.class}: #{e.message}" },
          duration_seconds
        )

        # Re-raise the error
        raise e
      end
    end

    # Log a request without executing it (for when patches capture the data directly)
    def log_completed_request(method, url, request_data, response_data, duration_seconds)
      return unless configuration.enabled?
      return unless configuration.should_log_url?(url)

      Models::OutboundRequestLog.log_request(
        method,
        url,
        request_data,
        response_data,
        duration_seconds
      )
    end

    private

      # Extract response data from various response types
      def extract_response_data(response)
        return { status_code: 0, headers: {}, body: nil } unless response

        case response
        when Net::HTTPResponse
          {
            status_code: response.code.to_i,
            headers: response.to_hash.transform_values(&:first),
            body: response.body
          }
        when Faraday::Response
          {
            status_code: response.status,
            headers: response.headers.to_h,
            body: response.body
          }
        when HTTParty::Response
          {
            status_code: response.code,
            headers: response.headers.to_h,
            body: response.body
          }
        when Hash
          # If it's already a hash, assume it's in the right format
          response
        else
          # Try to extract common attributes
          {
            status_code: response.try(:status) || response.try(:code) || 0,
            headers: response.try(:headers) || {},
            body: response.try(:body)
          }
        end
      end
  end
end

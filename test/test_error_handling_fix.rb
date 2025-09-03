# frozen_string_literal: true

require 'test_helper'

# Skip tests if optional dependencies are not available
begin
  require 'faraday'
  require 'httparty'
rescue LoadError
  # Will skip tests that require these libraries
end

class TestErrorHandlingFix < ActiveSupport::TestCase
  include OutboundHTTPLogger::Test::Helpers

  describe 'Error Handling Fix' do
    it 'allows application errors to pass through without logging them' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        # Stub a request that will raise an application error
        stub_request(:get, 'https://api.example.com/error')
          .to_raise(SocketError.new('Connection failed'))

        # The application error should be raised normally
        assert_raises(SocketError) do
          Net::HTTP.get_response(URI('https://api.example.com/error'))
        end

        # No request should be logged since it's an application error
        assert_no_request_logged(:get, 'https://api.example.com/error')
      end
    end

    it 'handles logging errors gracefully without breaking HTTP requests' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        # Stub a successful HTTP request
        stub_request(:get, 'https://api.example.com/success')
          .to_return(status: 200, body: 'OK')

        # Mock the logging to raise an error
        OutboundHTTPLogger::Models::OutboundRequestLog.stub(:log_request, -> { raise StandardError, 'Database error' }) do
          # The HTTP request should still succeed despite logging error
          response = Net::HTTP.get_response(URI('https://api.example.com/success'))

          assert_equal '200', response.code
          assert_equal 'OK', response.body
        end

        # No request should be logged due to the logging error
        assert_no_request_logged(:get, 'https://api.example.com/success')
      end
    end

    it 'logs successful requests normally' do
      OutboundHTTPLogger.with_configuration(enabled: true) do
        # Stub a successful HTTP request
        stub_request(:get, 'https://api.example.com/success')
          .to_return(status: 200, body: 'OK')

        # Make the request
        response = Net::HTTP.get_response(URI('https://api.example.com/success'))

        assert_equal '200', response.code

        # Request should be logged normally
        log = assert_request_logged(:get, 'https://api.example.com/success', 200)
        assert_equal 'OK', log.response_body
      end
    end

    it 'does not catch application errors in Faraday' do
      skip 'Faraday not available' unless defined?(Faraday)

      OutboundHTTPLogger.with_configuration(enabled: true) do
        # Stub a request that will raise an application error
        stub_request(:get, 'https://api.example.com/error')
          .to_raise(SocketError.new('Connection failed'))

        connection = Faraday.new

        # The application error should be raised normally (wrapped by Faraday)
        assert_raises(Faraday::ConnectionFailed) do
          connection.get('https://api.example.com/error')
        end

        # No request should be logged since it's an application error
        assert_no_request_logged(:get, 'https://api.example.com/error')
      end
    end

    it 'does not catch application errors in HTTParty' do
      skip 'HTTParty not available' unless defined?(HTTParty)

      OutboundHTTPLogger.with_configuration(enabled: true) do
        # Stub a request that will raise an application error
        stub_request(:get, 'https://api.example.com/error')
          .to_raise(SocketError.new('Connection failed'))

        # The application error should be raised normally
        assert_raises(SocketError) do
          HTTParty.get('https://api.example.com/error')
        end

        # No request should be logged since it's an application error
        assert_no_request_logged(:get, 'https://api.example.com/error')
      end
    end

    it 'handles observability errors gracefully' do
      OutboundHTTPLogger.with_configuration(enabled: true, observability_enabled: true) do
        # Stub a successful HTTP request
        stub_request(:get, 'https://api.example.com/success')
          .to_return(status: 200, body: 'OK')

        # Mock observability to raise an error
        OutboundHTTPLogger.observability.stub(:record_http_request, -> { raise StandardError, 'Observability error' }) do
          # The HTTP request should still succeed despite observability error
          response = Net::HTTP.get_response(URI('https://api.example.com/success'))

          assert_equal '200', response.code
          assert_equal 'OK', response.body
        end

        # Request should still be logged (only observability failed)
        log = assert_request_logged(:get, 'https://api.example.com/success', 200)
        assert_equal 'OK', log.response_body
      end
    end
  end
end

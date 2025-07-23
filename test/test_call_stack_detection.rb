# frozen_string_literal: true

require 'test_helper'
require 'httparty'

describe 'Call Stack Detection' do
  before do
    OutboundHTTPLogger::Patches::NetHTTPPatch.apply!
  end

  describe 'detect_calling_library configuration' do
    it 'detects HTTParty as calling library when enabled' do
      OutboundHTTPLogger.with_configuration(enabled: true, detect_calling_library: true) do
        stub_request(:get, 'https://api.example.com/test')
          .to_return(status: 200, body: 'OK')

        HTTParty.get('https://api.example.com/test')

        log = assert_request_logged(:get, 'https://api.example.com/test', 200)
        _(log.metadata['library']).must_equal 'httparty'
      end
    end

    it 'uses net_http as library when detection is disabled' do
      OutboundHTTPLogger.with_configuration(enabled: true, detect_calling_library: false) do
        stub_request(:get, 'https://api.example.com/test')
          .to_return(status: 200, body: 'OK')

        HTTParty.get('https://api.example.com/test')

        log = assert_request_logged(:get, 'https://api.example.com/test', 200)
        _(log.metadata['library']).must_equal 'net_http'
      end
    end

    it 'detects direct Net::HTTP usage correctly' do
      OutboundHTTPLogger.with_configuration(enabled: true, detect_calling_library: true) do
        stub_request(:get, 'https://api.example.com/direct')
          .to_return(status: 200, body: 'OK')

        uri = URI('https://api.example.com/direct')
        Net::HTTP.get_response(uri)

        log = assert_request_logged(:get, 'https://api.example.com/direct', 200)
        _(log.metadata['library']).must_equal 'net_http'
      end
    end
  end

  describe 'debug_call_stack_logging configuration' do
    it 'includes call stack when enabled' do
      OutboundHTTPLogger.with_configuration(enabled: true, debug_call_stack_logging: true) do
        stub_request(:get, 'https://api.example.com/debug')
          .to_return(status: 200, body: 'OK')

        HTTParty.get('https://api.example.com/debug')

        log = assert_request_logged(:get, 'https://api.example.com/debug', 200)
        _(log.metadata).must_include 'call_stack'
        _(log.metadata['call_stack']).must_be_kind_of Array
        _(log.metadata['call_stack']).wont_be_empty

        # Verify call stack contains meaningful information
        call_stack_string = log.metadata['call_stack'].join("\n")

        _(call_stack_string).must_include 'httparty'
      end
    end

    it 'excludes call stack when disabled' do
      OutboundHTTPLogger.with_configuration(enabled: true, debug_call_stack_logging: false) do
        stub_request(:get, 'https://api.example.com/no-debug')
          .to_return(status: 200, body: 'OK')

        HTTParty.get('https://api.example.com/no-debug')

        log = assert_request_logged(:get, 'https://api.example.com/no-debug', 200)
        _(log.metadata).wont_include 'call_stack'
      end
    end
  end

  describe 'configuration defaults' do
    it 'has correct default values' do
      config = OutboundHTTPLogger.configuration

      _(config.detect_calling_library?).must_equal true
      _(config.debug_call_stack_logging?).must_equal false
    end
  end

  describe 'library detection edge cases' do
    it 'handles unknown libraries gracefully' do
      OutboundHTTPLogger.with_configuration(enabled: true, detect_calling_library: true) do
        stub_request(:get, 'https://api.example.com/unknown')
          .to_return(status: 200, body: 'OK')

        # Simulate direct Net::HTTP call (no higher-level library)
        uri = URI('https://api.example.com/unknown')
        Net::HTTP.get_response(uri)

        log = assert_request_logged(:get, 'https://api.example.com/unknown', 200)
        _(log.metadata['library']).must_equal 'net_http'
      end
    end
  end
end

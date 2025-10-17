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

    it 'handles nil location.path gracefully (AWS SDK instrumentation case)' do
      OutboundHTTPLogger.with_configuration(enabled: true, detect_calling_library: true) do
        stub_request(:get, 'https://api.example.com/nil-path')
          .to_return(status: 200, body: 'OK')

        # Test that the code doesn't crash when location.path is nil
        # This simulates the AWS SDK instrumentation case where caller_locations
        # can include entries with nil paths
        uri = URI('https://api.example.com/nil-path')
        Net::HTTP.get_response(uri)

        log = assert_request_logged(:get, 'https://api.example.com/nil-path', 200)
        # Should not raise NoMethodError and should fall back to net_http
        _(log.metadata['library']).must_equal 'net_http'
      end
    end
  end

  describe 'nil path handling in patch behavior' do
    it 'detect_calling_library_from_stack skips nil paths' do
      # Create a test class that includes CommonPatchBehavior
      test_class = Class.new do
        include OutboundHTTPLogger::Patches::CommonPatchBehavior
      end
      instance = test_class.new

      # Mock caller_locations to return a mix of nil and valid paths
      mock_locations = [
        Struct.new(:path, :lineno, :label).new(nil, 10, 'method1'),
        Struct.new(:path, :lineno, :label).new('/some/path/httparty.rb', 20, 'method2'),
        Struct.new(:path, :lineno, :label).new(nil, 30, 'method3')
      ]

      # Stub caller_locations on the instance
      instance.define_singleton_method(:caller_locations) { mock_locations }

      # Should not raise NoMethodError and should detect httparty
      result = instance.send(:detect_calling_library_from_stack)

      _(result).must_equal 'httparty'
    end

    it 'capture_call_stack handles nil paths as <unknown>' do
      # Create a test class that includes CommonPatchBehavior
      test_class = Class.new do
        include OutboundHTTPLogger::Patches::CommonPatchBehavior
      end
      instance = test_class.new

      # Mock caller_locations to return a mix of nil and valid paths
      mock_locations = [
        Struct.new(:path, :lineno, :label).new(nil, 10, 'method1'),
        Struct.new(:path, :lineno, :label).new('/some/path/file.rb', 20, 'method2')
      ]

      # Stub caller_locations on the instance
      instance.define_singleton_method(:caller_locations) { mock_locations }

      # Should not raise NoMethodError
      result = instance.send(:capture_call_stack)

      _(result).must_be_kind_of Array
      _(result.length).must_equal 2
      _(result[0]).must_include '<unknown>:10:in `method1\''
      _(result[1]).must_include '/some/path/file.rb:20:in `method2\''
    end
  end
end

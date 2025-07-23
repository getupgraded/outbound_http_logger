# frozen_string_literal: true

require 'test_helper'

describe 'Faraday Adapter Validation' do
  describe 'adapter detection' do
    it 'detects Net::HTTP adapter correctly' do
      skip 'Faraday not available' unless defined?(Faraday)

      # Test with default adapter (should be Net::HTTP)
      _(OutboundHTTPLogger::Patches::FaradayPatch.using_net_http_adapter?).must_equal true
    end

    it 'handles missing Faraday gracefully' do
      # Temporarily hide Faraday constant
      faraday_const = Object.send(:remove_const, :Faraday) if defined?(Faraday)

      begin
        _(OutboundHTTPLogger::Patches::FaradayPatch.using_net_http_adapter?).must_equal false
      ensure
        Object.const_set(:Faraday, faraday_const) if faraday_const
      end
    end
  end

  describe 'patch application with validation' do
    it 'applies patch when using Net::HTTP adapter' do
      skip 'Faraday not available' unless defined?(Faraday)

      # Reset patch state
      OutboundHTTPLogger::Patches::FaradayPatch.instance_variable_set(:@applied, false)

      # Should apply successfully
      OutboundHTTPLogger::Patches::FaradayPatch.apply!

      _(OutboundHTTPLogger::Patches::FaradayPatch.applied?).must_equal true
    end

    it 'logs warning when Faraday is not using Net::HTTP adapter' do
      skip 'Faraday not available' unless defined?(Faraday)

      # Mock the adapter detection to return false
      OutboundHTTPLogger::Patches::FaradayPatch.stub(:using_net_http_adapter?, false) do
        # Capture log output
        log_output = StringIO.new
        logger = Logger.new(log_output)

        OutboundHTTPLogger.with_configuration(enabled: true, logger: logger) do
          # Reset patch state
          OutboundHTTPLogger::Patches::FaradayPatch.instance_variable_set(:@applied, false)

          OutboundHTTPLogger::Patches::FaradayPatch.apply!

          # Should not apply patch
          _(OutboundHTTPLogger::Patches::FaradayPatch.applied?).must_equal false

          # Should log warning
          log_content = log_output.string

          _(log_content).must_include 'Faraday patch skipped'
          _(log_content).must_include 'not using Net::HTTP adapter'
        end
      end
    end
  end

  describe 'integration with setup_patches' do
    it 'skips Faraday patch when adapter is not supported' do
      skip 'Faraday not available' unless defined?(Faraday)

      # Mock the adapter detection to return false
      OutboundHTTPLogger::Patches::FaradayPatch.stub(:using_net_http_adapter?, false) do
        log_output = StringIO.new
        logger = Logger.new(log_output)

        OutboundHTTPLogger.with_configuration(enabled: true, logger: logger, faraday_patch_enabled: true) do
          # Reset patch states
          OutboundHTTPLogger::Patches::NetHTTPPatch.instance_variable_set(:@applied, false)
          OutboundHTTPLogger::Patches::FaradayPatch.instance_variable_set(:@applied, false)

          # This should apply Net::HTTP patch but skip Faraday patch
          OutboundHTTPLogger.send(:setup_patches)

          _(OutboundHTTPLogger::Patches::NetHTTPPatch.applied?).must_equal true
          _(OutboundHTTPLogger::Patches::FaradayPatch.applied?).must_equal false

          # Should log warning about Faraday
          log_content = log_output.string

          _(log_content).must_include 'Faraday patch skipped'
        end
      end
    end
  end
end

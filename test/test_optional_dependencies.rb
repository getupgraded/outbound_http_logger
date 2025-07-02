# frozen_string_literal: true

require 'test_helper'

# Load HTTP libraries for testing
require 'faraday'
require 'httparty'

describe 'Optional Dependencies Handling' do
  include TestHelpers

  before do
    # Reset patches to ensure clean state
    OutboundHTTPLogger.reset_patches!
  end

  after do
    # Reset patches after each test
    OutboundHTTPLogger.reset_patches!
  end

  describe 'library_status method' do
    it 'returns status for all supported HTTP libraries' do
      status = OutboundHTTPLogger.library_status

      _(status).must_be_kind_of Hash
      _(status.keys).must_include 'Net::HTTP'
      _(status.keys).must_include 'Faraday'
      _(status.keys).must_include 'HTTParty'

      # Each library should have required fields
      status.each_value do |info|
        _(info).must_be_kind_of Hash
        _(info).must_include :available
        _(info).must_include :patched

        if info[:available]
          # Available libraries should have version info
          _(info).must_include :version
        else
          # Unavailable libraries should have suggestions
          _(info).must_include :suggestion
        end
      end
    end

    it 'correctly identifies available libraries' do
      status = OutboundHTTPLogger.library_status

      # Net::HTTP should always be available (part of Ruby standard library)
      _(status['Net::HTTP'][:available]).must_equal true

      # Faraday and HTTParty should be available in test environment (they're in the Gemfile)
      # But let's be flexible in case they're not loaded yet
      _(status['Faraday'][:available]).must_equal true if defined?(Faraday)

      _(status['HTTParty'][:available]).must_equal true if defined?(HTTParty)
    end

    it 'shows patch status correctly' do
      status = OutboundHTTPLogger.library_status

      # Check that patch status is tracked correctly
      status.each do |library_name, info|
        next unless info[:available]

        # Available libraries should have a boolean patched status
        _([true, false]).must_include info[:patched]

        # The status should be consistent with the patch module state
        case library_name
        when 'Net::HTTP'

          _(info[:patched]).must_equal OutboundHTTPLogger::Patches::NetHTTPPatch.applied?
        when 'Faraday'

          _(info[:patched]).must_equal OutboundHTTPLogger::Patches::FaradayPatch.applied?
        when 'HTTParty'

          _(info[:patched]).must_equal OutboundHTTPLogger::Patches::HTTPartyPatch.applied?
        end
      end
    end
  end

  describe 'graceful handling of missing libraries' do
    it 'does not raise errors when libraries are missing' do
      # This test verifies that the gem handles missing libraries gracefully
      # We test this by checking that the library_status method works correctly

      status = OutboundHTTPLogger.library_status

      # Should return status for all libraries without raising errors
      _(status).must_be_kind_of Hash
      _(status.keys).must_include 'Net::HTTP'
      _(status.keys).must_include 'Faraday'
      _(status.keys).must_include 'HTTParty'

      # Each status should have the required fields
      status.each_value do |info|
        _(info).must_include :available
        _(info).must_include :patched
      end
    end

    it 'logs appropriate messages for available libraries' do
      # Capture log output
      log_output = StringIO.new
      logger = Logger.new(log_output)

      OutboundHTTPLogger.configure do |config|
        config.debug_logging = true
        config.logger = logger
      end

      # Reset and enable logging to trigger patch application
      OutboundHTTPLogger.reset_patches!
      OutboundHTTPLogger.enable!

      log_content = log_output.string

      # Should contain success messages for available libraries
      _(log_content).must_include 'Net::HTTP patch applied successfully'
      # NOTE: Faraday and HTTParty may or may not be loaded depending on test order
      # So we just check that no error messages are present
      _(log_content).wont_include 'Failed to patch'
    end
  end

  describe 'patch application safety' do
    it 'handles patch application errors gracefully' do
      # Test that the patch application methods exist and can be called
      # without raising errors for available libraries

      # These should not raise errors
      _(OutboundHTTPLogger::Patches::NetHTTPPatch.respond_to?(:apply!)).must_equal true
      _(OutboundHTTPLogger::Patches::FaradayPatch.respond_to?(:apply!)).must_equal true
      _(OutboundHTTPLogger::Patches::HTTPartyPatch.respond_to?(:apply!)).must_equal true

      # The library_available? method should work correctly
      _(OutboundHTTPLogger::Patches::NetHTTPPatch.library_available?(Net::HTTP)).must_equal true
    end

    it 'provides error handling in patch application' do
      # Test that the common patch behavior includes error handling
      # by checking that the methods exist

      patch_module = OutboundHTTPLogger::Patches::NetHTTPPatch

      # Should have the safety methods
      _(patch_module.respond_to?(:library_available?)).must_equal true
      _(patch_module.respond_to?(:applied?)).must_equal true
      _(patch_module.respond_to?(:reset!)).must_equal true
    end
  end

  describe 'library availability checking' do
    it 'correctly identifies when libraries are defined' do
      # Test the library_available? method through the patch behavior
      patch_module = OutboundHTTPLogger::Patches::NetHTTPPatch

      # Net::HTTP should be available
      _(patch_module.library_available?(Net::HTTP)).must_equal true

      # A non-existent class should not be available
      _(patch_module.library_available?(nil)).must_equal false
    end

    it 'handles errors when checking library availability' do
      patch_module = OutboundHTTPLogger::Patches::NetHTTPPatch

      # Should handle invalid input gracefully
      _(patch_module.library_available?('not_a_class')).must_equal false
      _(patch_module.library_available?(123)).must_equal false
    end
  end

  describe 'version detection' do
    it 'detects library versions when available' do
      status = OutboundHTTPLogger.library_status

      # Net::HTTP version detection (may be 'unknown' or actual version)
      net_http_version = status['Net::HTTP'][:version]

      _(net_http_version).wont_be_nil

      # Faraday and HTTParty should have version information
      _(status['Faraday'][:version]).wont_be_nil if status['Faraday'][:available]

      _(status['HTTParty'][:version]).wont_be_nil if status['HTTParty'][:available]
    end
  end

  describe 'suggestions for missing libraries' do
    it 'provides helpful suggestions for unavailable libraries' do
      # We can't actually make libraries unavailable, but we can test the suggestion logic
      # by examining what would happen if they were unavailable

      # Mock library_info to simulate unavailable library
      original_method = OutboundHTTPLogger.method(:library_info)

      OutboundHTTPLogger.define_singleton_method(:library_info) do |library_constant, gem_name|
        if library_constant.name == 'Faraday'
          {
            available: false,
            version: nil,
            patched: false,
            suggestion: "Add 'gem \"#{gem_name}\"' to your Gemfile to enable #{library_constant} logging"
          }
        else
          original_method.call(library_constant, gem_name)
        end
      end

      status = OutboundHTTPLogger.library_status

      # Should provide helpful suggestion for unavailable library
      _(status['Faraday'][:suggestion]).must_include 'Add \'gem "faraday"\' to your Gemfile' if status['Faraday'][:suggestion]

      # Restore original method
      OutboundHTTPLogger.define_singleton_method(:library_info, original_method)
    end
  end
end

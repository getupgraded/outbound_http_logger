# frozen_string_literal: true

require 'test_helper'

# Load HTTP libraries for testing
begin
  require 'faraday'
rescue LoadError
  # Faraday not available
end

class TestGranularPatchControl < Minitest::Test
  def setup
    OutboundHTTPLogger.reset_configuration!
    OutboundHTTPLogger.reset_patches!
  end

  def teardown
    OutboundHTTPLogger.reset_configuration!
    OutboundHTTPLogger.reset_patches!
  end

  def test_default_patch_settings
    config = OutboundHTTPLogger.configuration

    assert_predicate config, :net_http_patch_enabled?
    assert_predicate config, :faraday_patch_enabled?
    assert_predicate config, :auto_patch_detection?
  end

  def test_patch_enabled_method
    config = OutboundHTTPLogger.configuration

    assert config.patch_enabled?('net_http')
    assert config.patch_enabled?('Net::HTTP')
    assert config.patch_enabled?('faraday')
    refute config.patch_enabled?('unknown')
  end

  def test_selective_patch_configuration
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = false
    end

    config = OutboundHTTPLogger.configuration

    assert_predicate config, :net_http_patch_enabled?
    refute_predicate config, :faraday_patch_enabled?
  end

  def test_patch_status_reporting
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = false
    end

    status = OutboundHTTPLogger.patch_status

    assert_kind_of Hash, status
    assert status.key?('Net::HTTP')
    assert status.key?('Faraday')

    # Check Net::HTTP status
    net_http_status = status['Net::HTTP']

    assert net_http_status[:enabled]
    assert net_http_status[:applied] # Should be applied after configure
    assert net_http_status[:library_available]
    assert net_http_status[:active]

    # Check Faraday status
    faraday_status = status['Faraday']

    refute faraday_status[:enabled]
    refute faraday_status[:applied] # Should not be applied when disabled
    refute faraday_status[:active]
  end

  def test_available_patches
    patches = OutboundHTTPLogger.available_patches

    assert_kind_of Array, patches
    assert_includes patches, 'Net::HTTP'
    assert_includes patches, 'Faraday'
  end

  def test_applied_patches
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = false
    end

    applied = OutboundHTTPLogger.applied_patches

    assert_kind_of Array, applied
    assert_includes applied, 'Net::HTTP'
    refute_includes applied, 'Faraday'
  end

  def test_active_patches
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = false
    end

    active = OutboundHTTPLogger.active_patches

    assert_kind_of Array, active
    assert_includes active, 'Net::HTTP'
    refute_includes active, 'Faraday'
  end

  def test_active_patches_when_disabled
    OutboundHTTPLogger.configure do |config|
      config.enabled = false
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = true
    end

    active = OutboundHTTPLogger.active_patches

    assert_empty active
  end

  def test_enable_patch_method
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = false
    end

    refute_predicate OutboundHTTPLogger.configuration, :net_http_patch_enabled?

    result = OutboundHTTPLogger.enable_patch('net_http')

    assert result
    assert_predicate OutboundHTTPLogger.configuration, :net_http_patch_enabled?
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?
  end

  def test_enable_patch_with_different_names
    OutboundHTTPLogger.configure { |config| config.enabled = true }

    assert OutboundHTTPLogger.enable_patch('net_http')
    assert OutboundHTTPLogger.enable_patch('Net::HTTP')
    assert OutboundHTTPLogger.enable_patch('faraday')
    refute OutboundHTTPLogger.enable_patch('unknown')
  end

  def test_disable_patch_method
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
    end

    assert_predicate OutboundHTTPLogger.configuration, :net_http_patch_enabled?

    result = OutboundHTTPLogger.disable_patch('net_http')

    assert result
    refute_predicate OutboundHTTPLogger.configuration, :net_http_patch_enabled?
  end

  def test_disable_patch_with_different_names
    OutboundHTTPLogger.configure { |config| config.enabled = true }

    assert OutboundHTTPLogger.disable_patch('net_http')
    assert OutboundHTTPLogger.disable_patch('Net::HTTP')
    assert OutboundHTTPLogger.disable_patch('faraday')
    refute OutboundHTTPLogger.disable_patch('unknown')
  end

  def test_patch_backup_and_restore
    OutboundHTTPLogger.configure do |config|
      config.net_http_patch_enabled = false
      config.faraday_patch_enabled = true
      config.auto_patch_detection = false
    end

    backup = OutboundHTTPLogger.configuration.backup

    OutboundHTTPLogger.configure do |config|
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = false
      config.auto_patch_detection = true
    end

    OutboundHTTPLogger.configuration.restore(backup)

    config = OutboundHTTPLogger.configuration

    refute_predicate config, :net_http_patch_enabled?
    assert_predicate config, :faraday_patch_enabled?
    refute_predicate config, :auto_patch_detection?
  end

  def test_selective_patch_application_with_logging
    output = StringIO.new
    logger = Logger.new(output)

    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.debug_logging = true
      config.logger = logger
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = false
    end

    log_output = output.string

    assert_includes log_output, 'Net::HTTP patch applied'
    assert_includes log_output, 'Faraday patch skipped - disabled in configuration'
  end

  def test_runtime_patch_disabling_with_logging
    output = StringIO.new
    logger = Logger.new(output)

    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.debug_logging = true
      config.logger = logger
    end

    # Clear previous logs by creating a new StringIO
    output = StringIO.new
    logger = Logger.new(output)
    OutboundHTTPLogger.configuration.logger = logger

    OutboundHTTPLogger.disable_patch('net_http')

    log_output = output.string

    assert_includes log_output, 'Net::HTTP patch disabled'
    assert_includes log_output, 'already applied patches will remain inactive until restart'
  end

  def test_patch_enabled_for_library_method
    config = OutboundHTTPLogger.configuration
    config.net_http_patch_enabled = true
    config.faraday_patch_enabled = false

    # Create a dummy object that includes CommonPatchBehavior to test the method
    dummy_class = Class.new do
      include OutboundHTTPLogger::Patches::CommonPatchBehavior
    end
    dummy = dummy_class.new

    assert dummy.send(:patch_enabled_for_library?, 'net_http', config)
    refute dummy.send(:patch_enabled_for_library?, 'faraday', config)
    refute dummy.send(:patch_enabled_for_library?, 'unknown', config)
  end

  def test_backward_compatibility
    # Test that existing behavior is preserved when using old configuration style
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      # Don't set individual patch settings - should default to all enabled
    end

    config = OutboundHTTPLogger.configuration

    assert_predicate config, :net_http_patch_enabled?
    assert_predicate config, :faraday_patch_enabled?

    # All available patches should be applied
    applied = OutboundHTTPLogger.applied_patches

    assert_includes applied, 'Net::HTTP'

    # Only check if libraries are available
    assert_includes applied, 'Faraday' if defined?(Faraday)
  end

  def test_configuration_validation
    config = OutboundHTTPLogger.configuration

    # Test that patch settings are properly validated
    config.net_http_patch_enabled = 'invalid'

    refute_predicate config, :net_http_patch_enabled?

    config.net_http_patch_enabled = true

    assert_predicate config, :net_http_patch_enabled?

    config.net_http_patch_enabled = false

    refute_predicate config, :net_http_patch_enabled?
  end
end

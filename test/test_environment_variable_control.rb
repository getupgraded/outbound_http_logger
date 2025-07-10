# frozen_string_literal: true

require 'test_helper'

class TestEnvironmentVariableControl < Minitest::Test
  def setup
    # Store original environment variable value
    @original_env_value = ENV.fetch('ENABLE_OUTBOUND_HTTP_LOGGER', nil)
  end

  def teardown
    # Restore original environment variable value
    if @original_env_value.nil?
      ENV.delete('ENABLE_OUTBOUND_HTTP_LOGGER')
    else
      ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = @original_env_value
    end
  end

  def test_gem_enabled_returns_true_when_env_var_is_nil
    ENV.delete('ENABLE_OUTBOUND_HTTP_LOGGER')

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_true_when_env_var_is_empty
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = ''

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_true_when_env_var_is_true
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'true'

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_true_when_env_var_is_TRUE # rubocop:disable Naming/MethodName
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'TRUE'

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_true_when_env_var_is_1 # rubocop:disable Naming/VariableNumber
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = '1'

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_true_when_env_var_is_yes
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'yes'

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_true_when_env_var_is_on
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'on'

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_false_when_env_var_is_false
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'false'

    refute_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_false_when_env_var_is_FALSE # rubocop:disable Naming/MethodName
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'FALSE'

    refute_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_false_when_env_var_is_0 # rubocop:disable Naming/VariableNumber
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = '0'

    refute_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_false_when_env_var_is_no
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'no'

    refute_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_false_when_env_var_is_off
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'off'

    refute_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_handles_whitespace
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = ' false '

    refute_predicate OutboundHTTPLogger, :gem_enabled?
  end

  def test_gem_enabled_returns_true_for_unknown_values
    ENV['ENABLE_OUTBOUND_HTTP_LOGGER'] = 'maybe'

    assert_predicate OutboundHTTPLogger, :gem_enabled?
  end
end

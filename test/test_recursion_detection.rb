# frozen_string_literal: true

require 'test_helper'

describe 'Recursion Detection' do
  let(:config) { OutboundHTTPLogger.configuration }

  before do
    # Clear any existing recursion state
    Thread.current[:outbound_http_logger_depth_faraday] = nil
    Thread.current[:outbound_http_logger_depth_net_http] = nil
    Thread.current[:outbound_http_logger_depth_httparty] = nil
    Thread.current[:outbound_http_logger_depth_test] = nil
  end

  after do
    # Clean up recursion state after each test
    Thread.current[:outbound_http_logger_depth_faraday] = nil
    Thread.current[:outbound_http_logger_depth_net_http] = nil
    Thread.current[:outbound_http_logger_depth_httparty] = nil
    Thread.current[:outbound_http_logger_depth_test] = nil
  end

  describe 'recursion depth tracking' do
    it 'tracks recursion depth correctly' do
      _(config.current_recursion_depth('test')).must_equal 0
      _(config.in_recursion?('test')).must_equal false

      config.increment_recursion_depth('test')

      _(config.current_recursion_depth('test')).must_equal 1
      _(config.in_recursion?('test')).must_equal true

      config.increment_recursion_depth('test')

      _(config.current_recursion_depth('test')).must_equal 2

      config.decrement_recursion_depth('test')

      _(config.current_recursion_depth('test')).must_equal 1

      config.decrement_recursion_depth('test')

      _(config.current_recursion_depth('test')).must_equal 0
      _(config.in_recursion?('test')).must_equal false
    end

    it 'prevents depth from going below zero' do
      _(config.current_recursion_depth('test')).must_equal 0

      config.decrement_recursion_depth('test')

      _(config.current_recursion_depth('test')).must_equal 0
    end

    it 'tracks different libraries independently' do
      config.increment_recursion_depth('faraday')
      config.increment_recursion_depth('net_http')

      _(config.current_recursion_depth('faraday')).must_equal 1
      _(config.current_recursion_depth('net_http')).must_equal 1
      _(config.current_recursion_depth('httparty')).must_equal 0

      config.decrement_recursion_depth('faraday')

      _(config.current_recursion_depth('faraday')).must_equal 0
      _(config.current_recursion_depth('net_http')).must_equal 1
    end
  end

  describe 'strict recursion detection' do
    before do
      config.strict_recursion_detection = true
      config.max_recursion_depth = 2
    end

    after do
      config.strict_recursion_detection = false
      config.max_recursion_depth = 3
    end

    it 'raises error when max depth exceeded' do
      config.increment_recursion_depth('test')

      _(config.current_recursion_depth('test')).must_equal 1

      # Should not raise at depth 1 (max is 2)
      config.check_recursion_depth!('test')

      config.increment_recursion_depth('test')

      _(config.current_recursion_depth('test')).must_equal 2

      # Should raise at depth 2 (>= max of 2)
      error = _(proc { config.check_recursion_depth!('test') }).must_raise OutboundHTTPLogger::InfiniteRecursionError
      _(error.message).must_include 'Infinite recursion detected in test'
      _(error.message).must_include 'depth: 2'
    end

    it 'provides helpful error message' do
      2.times { config.increment_recursion_depth('faraday') }

      error = _(proc { config.check_recursion_depth!('faraday') }).must_raise OutboundHTTPLogger::InfiniteRecursionError
      _(error.message).must_include 'faraday'
      _(error.message).must_include 'HTTP library is being used within the logging process'
      _(error.message).must_include 'Check your logger configuration'
    end
  end

  describe 'non-strict mode' do
    before do
      config.strict_recursion_detection = false
    end

    it 'does not raise errors even at high depth' do
      10.times { config.increment_recursion_depth('test') }

      # Should not raise in non-strict mode
      config.check_recursion_depth!('test')

      _(config.current_recursion_depth('test')).must_equal 10
    end
  end
end

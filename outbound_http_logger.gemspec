# frozen_string_literal: true

require_relative 'lib/outbound_http_logger/version'

Gem::Specification.new do |spec|
  spec.name    = 'outbound_http_logger'
  spec.version = OutboundHttpLogger::VERSION
  spec.authors = ['Ziad Sawalha']
  spec.email   = ['ziad@getupgraded.com']

  spec.summary               = 'Comprehensive outbound HTTP request logging for Rails applications'
  spec.description           = 'A gem for logging outbound HTTP requests with support for multiple HTTP libraries (Net::HTTP, Faraday, HTTParty), sensitive data filtering, and configurable exclusions.'
  spec.homepage              = 'https://github.com/getupgraded/outbound_http_logger'
  spec.license               = 'MIT'
  # Ruby 3.4 is not required; the gem works with Ruby 3.2+
  spec.required_ruby_version = '>= 3.2.0'

  # Specify which files should be added to the gem when it is released.
  spec.files            = Dir.glob('{lib,test}/**/*') + %w[README.md Rakefile outbound_http_logger.gemspec]
  spec.require_paths    = ['lib']
  spec.extra_rdoc_files = ['LICENSE.txt']

  # Runtime dependencies
  spec.add_dependency 'activerecord', '>= 7.2.0'
  spec.add_dependency 'activesupport', '>= 7.2.0'
  spec.add_dependency 'rack', '>= 2.0'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
  spec.metadata['rubygems_mfa_required'] = 'true'
end

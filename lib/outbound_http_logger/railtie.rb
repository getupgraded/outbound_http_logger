# frozen_string_literal: true

require 'rails/railtie'

module OutboundHTTPLogger
  class Railtie < Rails::Railtie
    # Only register components if the gem is enabled
    # This is a safety net in case the Railtie was loaded despite environment variable check

    # Add rake tasks
    rake_tasks do
      load File.expand_path('tasks/outbound_http_logger.rake', __dir__) if OutboundHTTPLogger.gem_enabled?
    end

    # Add generators
    generators do
      require_relative 'generators/migration_generator' if OutboundHTTPLogger.gem_enabled?
    end
  end
end

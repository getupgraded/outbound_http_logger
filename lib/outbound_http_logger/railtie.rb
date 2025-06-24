# frozen_string_literal: true

require 'rails/railtie'

module OutboundHttpLogger
  class Railtie < Rails::Railtie
    # Add rake tasks
    rake_tasks do
      load File.expand_path('tasks/outbound_http_logger.rake', __dir__)
    end

    # Add generators
    generators do
      require_relative 'generators/migration_generator'
    end
  end
end

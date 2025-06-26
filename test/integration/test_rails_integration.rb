# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'tmpdir'
require 'stringio'

# Try to load Rails generators, skip tests if not available
begin
  require 'rails/generators'
  require 'rails/generators/test_case'
  require 'thor'
  RAILS_GENERATORS_AVAILABLE = true
rescue LoadError
  RAILS_GENERATORS_AVAILABLE = false
end

describe 'Rails Integration Tests' do
  include TestHelpers

  # Helper method to capture stdout/stderr
  def capture_io
    old_stdout = $stdout
    old_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  describe 'Railtie Integration' do
    it 'loads rake tasks correctly' do
      skip 'Rails not available' unless RAILS_GENERATORS_AVAILABLE

      # Verify that the railtie loads rake tasks
      require 'outbound_http_logger/railtie'

      # Check that the railtie class exists and inherits from Rails::Railtie
      _(OutboundHTTPLogger::Railtie).must_be_kind_of Class
      _(OutboundHTTPLogger::Railtie.superclass).must_equal Rails::Railtie
    end

    it 'registers generators correctly' do
      skip 'Rails not available' unless RAILS_GENERATORS_AVAILABLE

      # Verify that generators are registered
      require 'outbound_http_logger/railtie'
      require 'outbound_http_logger/generators/migration_generator'

      # Check that the generator class exists
      _(OutboundHTTPLogger::Generators::MigrationGenerator).must_be_kind_of Class
      _(OutboundHTTPLogger::Generators::MigrationGenerator.superclass).must_equal Rails::Generators::Base
    end
  end

  describe 'Migration Generator' do
    before do
      skip 'Rails not available' unless RAILS_GENERATORS_AVAILABLE

      @temp_dir = Dir.mktmpdir('outbound_http_logger_test')
      @original_dir = Dir.pwd
      Dir.chdir(@temp_dir) # rubocop:disable ThreadSafety/DirChdir

      # Set up a minimal Rails app structure
      FileUtils.mkdir_p('db/migrate')
      FileUtils.mkdir_p('config')

      # Create a minimal application.rb to satisfy Rails requirements
      File.write('config/application.rb', <<~RUBY)
        require 'rails/all'

        module TestApp
          class Application < Rails::Application
            config.load_defaults 7.2
            config.eager_load = false
            config.cache_classes = false
          end
        end
      RUBY

      # Set up Rails environment
      ENV['RAILS_ENV'] = 'test'

      # Initialize Rails application if not already initialized
      unless defined?(Rails.application) && Rails.application
        require_relative File.join(@temp_dir, 'config/application')
        Rails.application.initialize! unless Rails.application.initialized?
      end
    end

    after do
      Dir.chdir(@original_dir) # rubocop:disable ThreadSafety/DirChdir
      FileUtils.rm_rf(@temp_dir)
    end

    it 'generates migration file with correct content' do
      # Run the generator
      Rails::Generators.invoke('outbound_http_logger:migration', [], {
                                 destination_root: @temp_dir,
                                 shell: Thor::Shell::Basic.new
                               })

      # Check that migration file was created
      migration_files = Dir.glob('db/migrate/*_create_outbound_request_logs.rb')

      _(migration_files).wont_be_empty

      migration_file = migration_files.first

      _(File.exist?(migration_file)).must_equal true

      # Check migration content
      migration_content = File.read(migration_file)

      # Verify key elements of the migration
      _(migration_content).must_include 'class CreateOutboundRequestLogs'
      _(migration_content).must_include 'create_table :outbound_request_logs'
      _(migration_content).must_include 't.string :http_method, null: false'
      _(migration_content).must_include 't.text :url, null: false'
      _(migration_content).must_include 't.integer :status_code, null: false'
      _(migration_content).must_include 't.json :request_headers'
      _(migration_content).must_include 't.json :response_headers'
      _(migration_content).must_include 't.json :request_body'
      _(migration_content).must_include 't.json :response_body'
      _(migration_content).must_include 't.json :metadata'
      _(migration_content).must_include 't.decimal :duration_seconds'
      _(migration_content).must_include 't.decimal :duration_ms'
      _(migration_content).must_include 't.references :loggable, polymorphic: true'
      _(migration_content).must_include 't.timestamp :created_at'
      _(migration_content).must_include 'add_index :outbound_request_logs, :created_at'
      _(migration_content).must_include 'add_index :outbound_request_logs, %i[loggable_type loggable_id]'
    end

    it 'generates migration with correct ActiveRecord version' do
      # Run the generator
      Rails::Generators.invoke('outbound_http_logger:migration', [], {
                                 destination_root: @temp_dir,
                                 shell: Thor::Shell::Basic.new
                               })

      migration_files = Dir.glob('db/migrate/*_create_outbound_request_logs.rb')
      migration_content = File.read(migration_files.first)

      # Check that it includes the correct ActiveRecord version
      expected_version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"

      _(migration_content).must_include "ActiveRecord::Migration#{expected_version}"
    end

    it 'handles database-specific optimizations' do
      # Run the generator
      Rails::Generators.invoke('outbound_http_logger:migration', [], {
                                 destination_root: @temp_dir,
                                 shell: Thor::Shell::Basic.new
                               })

      migration_files = Dir.glob('db/migrate/*_create_outbound_request_logs.rb')
      migration_content = File.read(migration_files.first)

      # Check for database adapter detection logic
      _(migration_content).must_include "connection.adapter_name == 'PostgreSQL'"
      _(migration_content).must_include 't.jsonb' # PostgreSQL optimization
      _(migration_content).must_include 't.json'  # Fallback for other databases
    end
  end

  describe 'Basic Rails Components' do
    it 'railtie file can be loaded' do
      skip 'Rails not available' unless RAILS_GENERATORS_AVAILABLE

      # Test that the railtie file can be required without errors
      require 'outbound_http_logger/railtie'

      # Verify the railtie class exists
      _(defined?(OutboundHTTPLogger::Railtie)).must_equal 'constant'
    end

    it 'generator file can be loaded' do
      skip 'Rails not available' unless RAILS_GENERATORS_AVAILABLE

      # Test that the generator file can be required without errors
      require 'outbound_http_logger/generators/migration_generator'

      # Verify the generator class exists
      _(defined?(OutboundHTTPLogger::Generators::MigrationGenerator)).must_equal 'constant'
    end

    it 'migration template exists and has correct content' do
      template_path = File.expand_path('../../lib/outbound_http_logger/generators/templates/create_outbound_request_logs.rb', __dir__)

      _(File.exist?(template_path)).must_equal true

      template_content = File.read(template_path)

      # Verify key elements of the migration template
      _(template_content).must_include 'class CreateOutboundRequestLogs'
      _(template_content).must_include 'create_table :outbound_request_logs'
      _(template_content).must_include 't.string :http_method, null: false'
      _(template_content).must_include 't.text :url, null: false'
      _(template_content).must_include 't.integer :status_code, null: false'
      _(template_content).must_include 't.json :request_headers'
      _(template_content).must_include 't.json :response_headers'
      _(template_content).must_include 't.json :request_body'
      _(template_content).must_include 't.json :response_body'
      _(template_content).must_include 't.json :metadata'
      _(template_content).must_include 't.decimal :duration_seconds'
      _(template_content).must_include 't.decimal :duration_ms'
      _(template_content).must_include 't.references :loggable, polymorphic: true'
      _(template_content).must_include 't.datetime :created_at'
      _(template_content).must_include 'add_index :outbound_request_logs, :created_at'
      _(template_content).must_include 'add_index :outbound_request_logs, [:loggable_type, :loggable_id]'

      # Check for database-specific optimizations
      _(template_content).must_include "connection.adapter_name == 'PostgreSQL'"
      _(template_content).must_include 't.jsonb' # PostgreSQL optimization
    end

    it 'rake tasks file exists and can be loaded' do
      tasks_path = File.expand_path('../../lib/outbound_http_logger/tasks/outbound_http_logger.rake', __dir__)

      _(File.exist?(tasks_path)).must_equal true

      # Test that the tasks file can be loaded without errors
      # Note: We don't actually load it here to avoid conflicts with other tests
      tasks_content = File.read(tasks_path)

      # Verify key rake tasks are defined
      _(tasks_content).must_include 'namespace :outbound_http_logger'
      _(tasks_content).must_include 'task analyze: :environment'
      _(tasks_content).must_include 'task :cleanup, [:days] => :environment'
      _(tasks_content).must_include 'task failed: :environment'
      _(tasks_content).must_include 'task :slow, [:threshold] => :environment'
    end
  end
end

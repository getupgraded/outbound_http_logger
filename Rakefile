# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'
require 'rubocop/rake_task'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  # Run all tests together (thread-safe with proper isolation)
  # Exclude tests that require special setup or aren't thread-safe
  t.test_files = FileList['test/**/*test*.rb'].exclude(
    'test/test_helper.rb', # Helper file, not a test
    'test/test_database_adapters.rb', # Run separately due to test utility thread safety
    'test/test_recursion_detection.rb' # Requires Rails.logger
  )
  t.verbose = true
end

# Separate task for faster feedback during development
Rake::TestTask.new(:test_fast) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  # Run core tests only for faster feedback
  t.test_files = FileList['test/**/*test*.rb'].exclude(
    'test/test_helper.rb', # Helper file, not a test
    'test/test_database_adapters.rb', # Slower database tests
    'test/test_recursion_detection.rb', # Requires Rails.logger
    'test/integration/**/*test*.rb' # Integration tests
  )
  t.verbose = true
end

# Database adapter tests - run separately due to test utility thread safety
Rake::TestTask.new(:test_database_adapters) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = ['test/test_database_adapters.rb']
  t.verbose = true
end

# Combined test task that runs both main tests and database adapter tests
desc 'Run all tests including database adapter tests'
task :test_all do # rubocop:disable Rails/RakeEnvironment
  Rake::Task[:test].invoke
  Rake::Task[:test_database_adapters].invoke
end

# RuboCop rake task - explicitly use local .rubocop.yml to avoid parent configs
RuboCop::RakeTask.new do |task|
  task.options = ['--config', '.rubocop.yml']
end

task default: :test

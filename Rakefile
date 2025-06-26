# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'
require 'rubocop/rake_task'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  # Run all tests together (thread-safe with proper isolation)
  # Exclude Rails-dependent tests that require special setup
  t.test_files = FileList['test/**/*test*.rb'].exclude(
    'test/test_helper.rb', # Helper file, not a test
    'test/test_database_adapters.rb', # Requires Rails environment
    'test/test_recursion_detection.rb' # Requires Rails.logger
  )
  t.verbose    = true
end

# RuboCop rake task - explicitly use local .rubocop.yml to avoid parent configs
RuboCop::RakeTask.new do |task|
  task.options = ['--config', '.rubocop.yml']
end

task default: :test

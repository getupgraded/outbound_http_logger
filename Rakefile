# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  # Run all tests together (thread-safe with proper isolation)
  # Exclude Rails-dependent tests that require special setup
  t.test_files = FileList["test/**/*test*.rb"].exclude(
    "test/test_helper.rb",           # Helper file, not a test
    "test/test_database_adapters.rb", # Requires Rails environment
    "test/test_recursion_detection.rb" # Requires Rails.logger
  )
  t.verbose    = true
end

task default: :test

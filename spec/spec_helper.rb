# frozen_string_literal: true

require 'simplecov'
require 'simplecov_json_formatter'

# Start SimpleCov
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/vendor/'
  add_filter '/lib/generators/'
  add_filter '/lib/jetstream_bridge/railtie.rb'
  enable_coverage :branch
  minimum_coverage line: 80, branch: 70

  # Use JSON formatter for Codecov
  formatter SimpleCov::Formatter::JSONFormatter
end

# Load the gem
require 'jetstream_bridge'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Suppress standard output during tests
  config.before(:all) do
    $stdout = StringIO.new
    $stderr = StringIO.new
  end

  config.after(:all) do
    $stdout = STDOUT
    $stderr = STDERR
  end
end

# frozen_string_literal: true

require 'simplecov'
require 'simplecov_json_formatter'

# Start SimpleCov with parallel test support
if ENV['COVERAGE'] != 'false'
  SimpleCov.start do
    add_filter '/spec/'
    add_filter '/vendor/'
    add_filter '/lib/generators/'
    add_filter '/lib/jetstream_bridge/rails/railtie.rb'
    enable_coverage :branch
    minimum_coverage line: 85, branch: 70

    # Merge results from parallel test processes
    command_name "RSpec-#{ENV['TEST_ENV_NUMBER']}" if ENV['TEST_ENV_NUMBER']

    # Use both JSON and HTML formatters
    formatter SimpleCov::Formatter::MultiFormatter.new([SimpleCov::Formatter::HTMLFormatter,
                                                        SimpleCov::Formatter::JSONFormatter])
  end
end

# Load the gem
require 'jetstream_bridge'

# Load support files (including compatibility helpers)
Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Performance optimizations
  config.order = :random

  # Run specs in random order to surface order dependencies
  Kernel.srand config.seed

  # Prevent actual NATS connections in tests by default
  # Individual specs should explicitly allow real connections if needed
  config.before(:each) do
    # Reset JetstreamBridge state before each test
    JetstreamBridge.reset! unless RSpec.current_example.metadata[:skip_reset]
  end

  # Optionally silence output for specific tests that need it
  # Usage: it 'example', :silence_output do
  config.around(:each, :silence_output) do |example|
    original_stdout = $stdout
    original_stderr = $stderr

    begin
      $stdout = StringIO.new
      $stderr = StringIO.new
      example.run
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end
end

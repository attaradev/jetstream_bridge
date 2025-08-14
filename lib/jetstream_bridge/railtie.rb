# frozen_string_literal: true

require 'rails/railtie'

module JetstreamBridge
  # Rails Railtie for JetstreamBridge.
  class Railtie < ::Rails::Railtie
    rake_tasks do
      # Load generators and tasks
      Dir[File.expand_path('tasks/**/*.rake', __dir__)].each { |f| load f }
    end

    # Load the Rails command
    initializer 'jetstream_bridge.load_commands' do |_app|
      require 'jetstream_bridge/commands'
    end
  end
end

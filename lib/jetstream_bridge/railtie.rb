# frozen_string_literal: true

require 'rails/railtie'

module JetstreamBridge
  # Rails integration for JetstreamBridge.
  class Railtie < ::Rails::Railtie
    # Load the Rails command
    initializer 'jetstream_bridge.load_commands' do
      require 'jetstream_bridge/commands'
    end

    # Load generators
    config.app_generators do |g|
      g.templates.unshift File.expand_path('../../generators', __dir__)
    end
  end
end

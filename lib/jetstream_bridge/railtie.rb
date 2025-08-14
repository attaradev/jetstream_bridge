# frozen_string_literal: true

require 'rails/railtie'

module JetstreamBridge
  # Rails Railtie
  class Railtie < ::Rails::Railtie
    initializer 'jetstream_bridge.load_commands' do
      # Load our custom Rails command (`rails jetstream_bridge:install`)
      require 'rails/commands/jetstream_bridge/install_command'
    end
  end
end

# frozen_string_literal: true

require 'rails/generators'

module JetstreamBridge
  module Generators
    # Install generator.
    class InstallGenerator < ::Rails::Generators::Base
      desc 'Creates JetstreamBridge initializer and migrations'
      def create_initializer
        ::Rails::Generators.invoke('jetstream_bridge:initializer', [], behavior: behavior,
                                                                       destination_root: destination_root)
      end

      def create_migrations
        ::Rails::Generators.invoke('jetstream_bridge:migrations', [], behavior: behavior,
                                                                      destination_root: destination_root)
      end
    end
  end
end

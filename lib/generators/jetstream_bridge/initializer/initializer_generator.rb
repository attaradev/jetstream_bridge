# frozen_string_literal: true

require 'rails/generators'

module JetstreamBridge
  module Generators
    class InitializerGenerator < ::Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)
      desc 'Creates config/initializers/jetstream_bridge.rb'

      def create_initializer
        template 'jetstream_bridge.rb', 'config/initializers/jetstream_bridge.rb'
      end
    end
  end
end

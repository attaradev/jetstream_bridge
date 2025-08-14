# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'

module JetstreamBridge
  module Generators
    # Generator for JetstreamBridge initializer and migrations.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path('templates', __dir__)

      desc 'Sets up JetstreamBridge with initializer and optional Inbox/Outbox migrations'

      class_option :inbox,  type: :boolean, default: false, desc: 'Create Inbox migration'
      class_option :outbox, type: :boolean, default: false, desc: 'Create Outbox migration'
      class_option :all,    type: :boolean, default: false, desc: 'Create both Inbox and Outbox migrations'

      def create_initializer
        template 'jetstream_bridge_initializer.rb', 'config/initializers/jetstream_bridge.rb'
      end

      def create_inbox_migration
        return unless options[:inbox] || options[:all]

        migration_template(
          'create_jetstream_inbox_events.rb',
          "db/migrate/#{migration_name('create_jetstream_inbox_events')}.rb"
        )
      end

      def create_outbox_migration
        return unless options[:outbox] || options[:all]

        migration_template(
          'create_jetstream_outbox_events.rb',
          "db/migrate/#{migration_name('create_jetstream_outbox_events')}.rb"
        )
      end

      private

      def migration_name(base_name)
        "#{base_name}_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
      end
    end
  end
end

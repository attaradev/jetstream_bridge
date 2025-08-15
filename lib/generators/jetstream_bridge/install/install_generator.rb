# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'

module JetstreamBridge
  module Generators
    # Copies initializer and (optionally) inbox/outbox migrations.
    #
    # Typical invocations (via our Rails command):
    #   rails jetstream_bridge:install
    #   rails jetstream_bridge:install --inbox
    #   rails jetstream_bridge:install --outbox
    #   rails jetstream_ridge:install --all
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)
      desc 'Sets up JetstreamBridge with initializer and optional Inbox/Outbox migrations'

      class_option :inbox,  type: :boolean, default: false, desc: 'Create Inbox migration'
      class_option :outbox, type: :boolean, default: false, desc: 'Create Outbox migration'
      class_option :all, type: :boolean, default: false, desc: 'Create both Inbox and Outbox migrations'

      # Rails::Generators::Migration requires this
      def self.next_migration_number(dirname)
        if ActiveRecord::Base.timestamped_migrations
          Time.now.utc.strftime('%Y%m%d%H%M%S')
        else
          format('%.3d', current_migration_number(dirname) + 1)
        end
      end

      def create_initializer
        template 'jetstream_bridge_initializer.rb', 'config/initializers/jetstream_bridge.rb'
      end

      def create_inbox_migration
        return unless options[:inbox] || options[:all]

        migration_template 'create_jetstream_inbox_events.rb', 'db/migrate/create_jetstream_inbox_events.rb'
      end

      def create_outbox_migration
        return unless options[:outbox] || options[:all]

        migration_template 'create_jetstream_outbox_events.rb', 'db/migrate/create_jetstream_outbox_events.rb'
      end

      def post_install_note
        readme 'README' if behavior == :invoke
      end
    end
  end
end

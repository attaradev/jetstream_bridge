# frozen_string_literal: true
require 'rails/generators'
require 'rails/generators/migration'

module JetstreamBridge
  module Generators
    # Sets up JetstreamBridge with initializer and optional Inbox/Outbox migrations.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path('templates', __dir__)

      desc 'Sets up JetstreamBridge with initializer and optional Inbox/Outbox migrations'

      class_option :inbox,  type: :boolean, default: false, desc: 'Create Inbox migration'
      class_option :outbox, type: :boolean, default: false, desc: 'Create Outbox migration'
      class_option :all,    type: :boolean, default: false, desc: 'Create both Inbox and Outbox migrations'

      def self.next_migration_number(dirname)
        if ActiveRecord::Base.timestamped_migrations
          Time.now.utc.strftime('%Y%m%d%H%M%S')
        else
          format('%.3d', (current_migration_number(dirname) + 1))
        end
      end

      def create_initializer
        template 'jetstream_bridge_initializer.rb', 'config/initializers/jetstream_bridge.rb'
      end

      def create_inbox_migration
        return unless options[:inbox] || options[:all]
        migration_template(
          'create_jetstream_inbox_events.rb.erb',
          "db/migrate/#{migration_name('create_jetstream_inbox_events')}.rb"
        )
      end

      def create_outbox_migration
        return unless options[:outbox] || options[:all]
        migration_template(
          'create_jetstream_outbox_events.rb.erb',
          "db/migrate/#{migration_name('create_jetstream_outbox_events')}.rb"
        )
      end

      def post_install_message
        puts "\n✅ JetstreamBridge setup complete!"
        puts "   - Initializer: config/initializers/jetstream_bridge.rb"
        puts "   - Migrations: #{migrations_created.join(', ')}" if migrations_created.any?
        puts "\nNext steps:"
        puts "   1. Configure the initializer."
        puts "   2. Run `rails db:migrate` if migrations were created."
      end

      private

      def migration_name(base_name)
        "#{base_name}_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
      end

      def migrations_created
        @migrations_created ||= []
      end

      def migration_template(source, destination)
        migrations_created << File.basename(destination)
        super
      end
    end
  end
end

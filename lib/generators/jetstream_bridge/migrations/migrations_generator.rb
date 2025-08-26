# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module JetstreamBridge
  module Generators
    # Migrations generator.
    class MigrationsGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)
      desc 'Creates Inbox/Outbox migrations for JetstreamBridge'

      def create_outbox_migration
        name = 'create_jetstream_outbox_events'
        return say_status :skip, "migration #{name} already exists", :yellow if migration_exists?('db/migrate', name)

        migration_template 'create_jetstream_outbox_events.rb.erb', "db/migrate/#{name}.rb"
      end

      def create_inbox_migration
        name = 'create_jetstream_inbox_events'
        return say_status :skip, "migration #{name} already exists", :yellow if migration_exists?('db/migrate', name)

        migration_template 'create_jetstream_inbox_events.rb.erb', "db/migrate/#{name}.rb"
      end

      # -- Rails::Generators::Migration plumbing --
      def self.next_migration_number(dirname)
        if ActiveRecord::Base.timestamped_migrations
          Time.now.utc.strftime('%Y%m%d%H%M%S')
        else
          format('%.3d', current_migration_number(dirname) + 1)
        end
      end

      private

      def migration_exists?(dirname, file_name)
        Dir.glob(File.join(dirname, '[0-9]*_*.rb')).grep(/\d+_#{file_name}\.rb$/).any?
      end
    end
  end
end

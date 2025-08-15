# frozen_string_literal: true

require 'rails/command'
require 'rails/generators'

module JetstreamBridge
  module Commands
    module Install
      # Usage:
      #   rails jetstream_bridge:install [--inbox] [--outbox]
      #
      # Examples:
      #   rails jetstream_bridge:install
      #   rails jetstream_bridge:install --inbox
      #   rails jetstream_bridge:install --outbox
      #   rails jetstream_bridge:install --inbox --outbox
      class InstallCommand < Rails::Command::Base
        class_option :inbox,  type: :boolean, default: false, desc: 'Create Inbox migration'
        class_option :outbox, type: :boolean, default: false, desc: 'Create Outbox migration'

        def perform
          say '→ Running jetstream_bridge install…', :green

          args = []
          args << '--inbox'  if options[:inbox]
          args << '--outbox' if options[:outbox]

          Rails::Generators.invoke('jetstream_bridge:install', args, behavior: :invoke,
                                                                     destination_root: Rails.root.to_s)

          say '✓ jetstream_bridge install complete.', :green
        end

        # Alias so `rails jetstream_bridge:install` calls #perform
        def self.banner(*)
          'rails jetstream_bridge:install [options]'
        end
      end
    end
  end
end

# Register the command namespace so `rails jetstream_bridge:install` works
Rails::Command::Base.subcommand('jetstream_bridge:install', JetstreamBridge::Commands::Install::InstallCommand)

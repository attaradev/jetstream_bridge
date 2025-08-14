# frozen_string_literal: true

require 'rails/command'
require 'rails/generators'

module JetstreamBridge
  module Commands
    module Install
      # Rails command for installing JetstreamBridge.
      class InstallCommand < Rails::Command::Base
        class_option :inbox,  type: :boolean, default: false, desc: 'Create Inbox migration'
        class_option :outbox, type: :boolean, default: false, desc: 'Create Outbox migration'
        class_option :all,    type: :boolean, default: false, desc: 'Create both Inbox and Outbox migrations'

        def perform
          say '→ Running jetstream_bridge install…', :green

          args = []
          args << '--inbox'  if options[:inbox] || options[:all]
          args << '--outbox' if options[:outbox] || options[:all]

          Rails::Generators.invoke(
            'jetstream_bridge:install',
            args,
            behavior: :invoke,
            destination_root: Rails.root.to_s
          )

          say '✓ jetstream_bridge install complete.', :green
        end

        def self.banner(*)
          'rails jetstream_bridge:install [options]'
        end

        def self.desc(*)
          'Install jetstream_bridge with optional Inbox, Outbox, or both migrations'
        end
      end
    end
  end
end

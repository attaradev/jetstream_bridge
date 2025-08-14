# frozen_string_literal: true

require 'rails/command'
require_relative 'commands/install'

module JetstreamBridge
  # Namespace for JetstreamBridge commands.
  module Commands
    # Register the command with Rails
    Rails::Command::Base.subcommand(
      'jetstream_bridge:install',
      JetstreamBridge::Commands::Install::InstallCommand
    )
  end
end

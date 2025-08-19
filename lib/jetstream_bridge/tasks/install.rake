# frozen_string_literal: true

namespace :jetstream_bridge do
  desc 'Install JetstreamBridge (initializer + migrations)'
  task install: :environment do
    puts '[jetstream_bridge] Generating initializer and migrations...'
    Rails::Generators.invoke('jetstream_bridge:install', [], behavior: :invoke, destination_root: Rails.root.to_s)
    puts '[jetstream_bridge] Done.'
  end
end

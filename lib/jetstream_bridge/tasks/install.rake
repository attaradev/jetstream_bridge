# frozen_string_literal: true

namespace :jetstream_bridge do
  desc 'Install JetstreamBridge (initializer + migrations)'
  task install: :environment do
    puts '[jetstream_bridge] Generating initializer and migrations...'
    Rails::Generators.invoke('jetstream_bridge:install', [], behavior: :invoke, destination_root: Rails.root.to_s)
    puts '[jetstream_bridge] Done.'
  end

  desc 'Check health and connection status'
  task health: :environment do
    require 'json'

    puts '=' * 70
    puts 'JetStream Bridge Health Check'
    puts '=' * 70

    health = JetstreamBridge.health_check

    puts "\nStatus: #{health[:healthy] ? '✓ HEALTHY' : '✗ UNHEALTHY'}"
    puts "NATS Connected: #{health[:nats_connected] ? 'Yes' : 'No'}"
    puts "Connected At: #{health[:connected_at] || 'N/A'}"
    puts "Version: #{health[:version]}"

    if health[:stream]
      puts "\nStream:"
      puts "  Name: #{health[:stream][:name]}"
      puts "  Exists: #{health[:stream][:exists] ? 'Yes' : 'No'}"
      if health[:stream][:subjects]
        puts "  Subjects: #{health[:stream][:subjects].join(', ')}"
        puts "  Messages: #{health[:stream][:messages]}"
      end
      puts "  Error: #{health[:stream][:error]}" if health[:stream][:error]
    end

    if health[:config]
      puts "\nConfiguration:"
      puts "  Environment: #{health[:config][:env]}"
      puts "  App Name: #{health[:config][:app_name]}"
      puts "  Destination: #{health[:config][:destination_app] || 'NOT SET'}"
      puts "  Outbox: #{health[:config][:use_outbox] ? 'Enabled' : 'Disabled'}"
      puts "  Inbox: #{health[:config][:use_inbox] ? 'Enabled' : 'Disabled'}"
      puts "  DLQ: #{health[:config][:use_dlq] ? 'Enabled' : 'Disabled'}"
    end

    if health[:error]
      puts "\n#{' ERROR '.center(70, '=')}"
      puts health[:error]
    end

    puts '=' * 70

    exit(health[:healthy] ? 0 : 1)
  end

  desc 'Validate configuration'
  task validate: :environment do
    puts '[jetstream_bridge] Validating configuration...'

    begin
      JetstreamBridge.config.validate!
      puts '✓ Configuration is valid'
      puts "\nCurrent settings:"
      puts "  App Name: #{JetstreamBridge.config.app_name}"
      puts "  Destination: #{JetstreamBridge.config.destination_app}"
      puts "  Stream: #{JetstreamBridge.config.stream_name}"
      puts "  Source Subject: #{JetstreamBridge.config.source_subject}"
      puts "  Destination Subject: #{JetstreamBridge.config.destination_subject}"
      exit 0
    rescue JetstreamBridge::ConfigurationError => e
      puts "✗ Configuration error: #{e.message}"
      exit 1
    end
  end

  desc 'Show debug information'
  task debug: :environment do
    JetstreamBridge::DebugHelper.debug_info
  end

  desc 'Test connection to NATS'
  task test_connection: :environment do
    puts '[jetstream_bridge] Testing NATS connection...'

    begin
      jts = JetstreamBridge.connect_and_ensure_stream!
      puts '✓ Successfully connected to NATS'
      puts '✓ JetStream is available'
      puts '✓ Stream topology ensured'

      # Check if we can get account info
      info = jts.account_info
      puts "\nAccount Info:"
      puts "  Memory: #{info.memory}"
      puts "  Storage: #{info.storage}"
      puts "  Streams: #{info.streams}"
      puts "  Consumers: #{info.consumers}"

      exit 0
    rescue StandardError => e
      puts "✗ Connection failed: #{e.message}"
      puts "\nBacktrace:" if ENV['VERBOSE']
      puts e.backtrace.first(10).map { |line| "  #{line}" }.join("\n") if ENV['VERBOSE']
      exit 1
    end
  end
end

#!/usr/bin/env ruby
# frozen_string_literal: true

# Provisioner Script for Restrictive Environment
# Runs with ADMIN permissions to pre-create streams and consumers.

require 'bundler/setup'
require 'jetstream_bridge'
require 'logger'

logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '=' * 70
puts 'JetStream Bridge Provisioner - Restrictive Environment'
puts '=' * 70
puts

NATS_URL = ENV.fetch('NATS_URL', 'nats://nats:4222')
STREAM_NAME = ENV.fetch('STREAM_NAME', 'sync-stream')

begin
  JetstreamBridge::Provisioner.provision_bidirectional!(
    app_a: 'system_a',
    app_b: 'system_b',
    stream_name: STREAM_NAME,
    nats_url: NATS_URL,
    logger: logger,
    max_deliver: 5,
    ack_wait: '30s',
    backoff: %w[1s 5s 15s 30s 60s],
    consumer_mode: ENV.fetch('CONSUMER_MODE', 'pull').to_sym
  )

  logger.info '=' * 70
  logger.info '✓ Bidirectional provisioning completed!'
  logger.info '=' * 70
rescue StandardError => e
  logger.error "✗ Provisioning failed: #{e.message}"
  logger.error e.backtrace.join("\n")
  exit 1
end

# frozen_string_literal: true

# JetStream Bridge Configuration for System B (Bidirectional, Restrictive)

require 'jetstream_bridge/config_helpers'

JetstreamBridge::ConfigHelpers.configure_bidirectional(
  app_name: 'system_b',
  destination_app: 'system_a',
  stream_name: ENV.fetch('STREAM_NAME', 'sync-stream'),
  mode: :restrictive,
  logger: Rails.logger
)

Rails.logger.level = :debug if Rails.env.development?
JetstreamBridge::ConfigHelpers.setup_rails_lifecycle

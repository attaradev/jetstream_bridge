# frozen_string_literal: true

# JetStream Bridge Configuration for System A (Bidirectional, Restrictive)

require 'jetstream_bridge/config_helpers'

JetstreamBridge::ConfigHelpers.configure_bidirectional(
  app_name: 'system_a',
  destination_app: 'system_b',
  stream_name: ENV.fetch('STREAM_NAME', 'sync-stream'),
  mode: :restrictive,
  logger: Rails.logger
)

Rails.logger.level = :debug if Rails.env.development?
JetstreamBridge::ConfigHelpers.setup_rails_lifecycle

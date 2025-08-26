# frozen_string_literal: true

# Jetstream Bridge configuration
JetstreamBridge.configure do |config|
  # NATS Connection
  config.nats_urls       = ENV.fetch('NATS_URLS', 'nats://localhost:4222')
  config.env             = ENV.fetch('NATS_ENV',  Rails.env)
  config.app_name        = ENV.fetch('APP_NAME',  Rails.application.class.module_parent_name.underscore)
  config.destination_app = ENV.fetch('DESTINATION_APP', nil) # required for cross-app data sync

  # Consumer Tuning
  config.max_deliver = 5
  config.ack_wait    = '30s'
  config.backoff     = %w[1s 5s 15s 30s 60s]

  # Reliability Features
  config.use_outbox = false
  config.use_inbox  = false
  config.use_dlq    = true

  # Models (override if you keep custom AR classes)
  config.outbox_model = 'JetstreamBridge::OutboxEvent'
  config.inbox_model  = 'JetstreamBridge::InboxEvent'

  # Logging
  # config.logger = Rails.logger
end

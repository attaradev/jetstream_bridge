# frozen_string_literal: true

# JetstreamBridge initializer
JetstreamBridge.configure do |config|
  config.nats_urls       = ENV['NATS_URLS'] || ENV['NATS_URL'] || 'nats://localhost:4222'
  config.env             = Rails.env
  config.app_name        = ENV['APP_NAME'] || Rails.application.class.module_parent_name&.underscore
  config.destination_app = ENV['DESTINATION_APP'] # e.g. "hw" or "pwas"

  config.max_deliver = (ENV['JETSTREAM_MAX_DELIVER'] || 5).to_i
  config.ack_wait    = ENV['JETSTREAM_ACK_WAIT'] || '30s'
  config.backoff     = ENV['JETSTREAM_BACKOFF']&.split(',') || %w[1s 5s 15s 30s 60s]

  # Reliability toggles (enable only if you want persisted guarantees)
  config.use_outbox   = ActiveModel::Type::Boolean.new.cast(ENV['JETSTREAM_USE_OUTBOX'] || false)
  config.outbox_model = 'JetstreamBridge::OutboxEvent' # override if using your own model
  config.use_inbox    = ActiveModel::Type::Boolean.new.cast(ENV['JETSTREAM_USE_INBOX'] || false)
  config.inbox_model  = 'JetstreamBridge::InboxEvent'  # override if using your own model

  # DLQ is generally recommended even with inbox/outbox
  config.use_dlq = ActiveModel::Type::Boolean.new.cast(ENV['JETSTREAM_USE_DLQ'] || true)
end

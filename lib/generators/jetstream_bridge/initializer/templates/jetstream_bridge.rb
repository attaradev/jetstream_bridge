# frozen_string_literal: true

# JetstreamBridge configuration
# See https://github.com/your-org/jetstream_bridge for full documentation
#
# This initializer configures the JetStream Bridge gem for Rails applications.
# The gem provides reliable, production-ready message passing between services
# using NATS JetStream with support for outbox/inbox patterns, DLQ, and more.
JetstreamBridge.configure do |config|
  # ============================================================================
  # NATS Connection Settings
  # ============================================================================
  # NATS server URLs (comma-separated for cluster)
  config.nats_urls = ENV.fetch('NATS_URLS', 'nats://localhost:4222')

  # Application name (used in subject routing)
  config.app_name = ENV.fetch('APP_NAME', Rails.application.class.module_parent_name.underscore)

  # Destination app for cross-app sync (REQUIRED for publishing/consuming)
  config.destination_app = ENV.fetch('DESTINATION_APP', nil)

  # ============================================================================
  # Consumer Settings
  # ============================================================================
  # Maximum delivery attempts before moving message to DLQ
  config.max_deliver = 5

  # How long to wait for message acknowledgment
  config.ack_wait = '30s'

  # Exponential backoff delays between retry attempts
  config.backoff = %w[1s 5s 15s 30s 60s]

  # ============================================================================
  # Reliability Features
  # ============================================================================
  # Enable transactional outbox pattern for guaranteed message delivery
  config.use_outbox = false

  # Enable inbox pattern for exactly-once processing (idempotency)
  config.use_inbox = false

  # Enable Dead Letter Queue for failed messages
  config.use_dlq = true

  # ============================================================================
  # Active Record Models
  # ============================================================================
  # Override these if you've created custom model classes
  config.outbox_model = 'JetstreamBridge::OutboxEvent'
  config.inbox_model = 'JetstreamBridge::InboxEvent'

  # ============================================================================
  # Logging
  # ============================================================================
  # Custom logger (defaults to Rails.logger if not set)
  # config.logger = Rails.logger
end

# Validate configuration (optional but recommended for development)
# Uncomment to enable validation on Rails boot
# begin
#   JetstreamBridge.config.validate!
#   Rails.logger.info "[JetStream Bridge] Configuration validated successfully"
# rescue JetstreamBridge::ConfigurationError => e
#   Rails.logger.error "[JetStream Bridge] Configuration error: #{e.message}"
#   raise if Rails.env.production?
# end

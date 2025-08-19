# frozen_string_literal: true

module JetstreamBridge
  class Config
    attr_accessor :destination_app, :nats_urls, :env, :app_name,
                  :max_deliver, :ack_wait, :backoff,
                  :use_outbox, :use_inbox, :inbox_model, :outbox_model,
                  :use_dlq

    def initialize
      @nats_urls       = ENV['NATS_URLS'] || ENV['NATS_URL'] || 'nats://localhost:4222'
      @env             = ENV['NATS_ENV']  || 'development'
      @app_name        = ENV['APP_NAME']  || 'app'
      @destination_app = ENV.fetch('DESTINATION_APP', nil)

      @max_deliver = 5
      @ack_wait    = '30s'
      @backoff     = %w[1s 5s 15s 30s 60s]

      @use_outbox   = false
      @use_inbox    = false
      @use_dlq      = true
      @outbox_model = 'JetstreamBridge::OutboxEvent'
      @inbox_model  = 'JetstreamBridge::InboxEvent'
    end

    # Single stream name per env
    def stream_name
      "#{env}-jetstream-bridge-stream"
    end

    # Base subjects
    # Producer publishes to:   {env}.sync.{app}.{dest}
    # Consumer subscribes to:  {env}.sync.{dest}.{app}
    def source_subject
      "#{env}.#{app_name}.sync.#{destination_app}"
    end

    def destination_subject
      "#{env}.#{destination_app}.sync.#{app_name}"
    end

    # DLQ
    def dlq_subject
      "#{env}.sync.dlq"
    end

    def durable_name
      "#{env}-#{app_name}-workers"
    end
  end
end

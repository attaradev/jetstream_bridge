# frozen_string_literal: true

module JetstreamBridge
  # JetstreamBridge::Config
  #
  # Stream name and subjects are derived from env.
  # Subjects (env-scoped):
  #   Publish:   {env}.data.sync.{app}.{dest}.{resource}.{event}
  #   Subscribe: {env}.data.sync.{dest}.{app}.>
  #   DLQ:       {env}.data.sync.dlq
  class Config
    attr_accessor :destination_app, :nats_urls, :env, :app_name,
                  :max_deliver, :ack_wait, :backoff,
                  :use_outbox, :use_inbox, :inbox_model, :outbox_model,
                  :use_dlq

    def initialize
      @nats_urls       = ENV['NATS_URLS'] || ENV['NATS_URL'] || 'nats://localhost:4222'
      @env             = ENV['NATS_ENV']  || 'development'
      @app_name        = ENV['APP_NAME']  || 'app'
      @destination_app = ENV['DESTINATION_APP']

      @max_deliver = 5
      @ack_wait    = '30s'
      @backoff     = %w[1s 5s 15s 30s 60s]

      @use_outbox   = false
      @use_inbox    = false
      @use_dlq      = true
      @outbox_model = 'JetstreamBridge::OutboxEvent'
      @inbox_model  = 'JetstreamBridge::InboxEvent'
    end

    # Derived
    def stream_name
      "#{env}-stream-bridge"
    end

    # {env}.data.sync.dlq
    def dlq_subject
      "#{env}.data.sync.dlq"
    end

    # {env}.data.sync.{dest}.{app}
    def dest_subject
      "#{env}.data.sync.#{destination_app}.#{app_name}"
    end

    # {env}.data.sync.{app}.{dest}
    def source_subject
      "#{env}.data.sync.#{app_name}.#{destination_app}"
    end

    def source_app
      app_name
    end
  end
end

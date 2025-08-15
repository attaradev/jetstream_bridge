# frozen_string_literal: true

module JetstreamBridge
  # JetstreamBridge::Config
  #
  # Stream name and DLQ subject are derived from env
  # Subjects:
  #   Publish:   data.sync.{app}.{dest}.{resource}.{event}
  #   Subscribe: data.sync.{dest}.{app}.>
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

    def dlq_subject
      'data.sync.dlq'
    end

    # data.sync.{dest}.{app}
    def dest_subject
      "data.sync.#{destination_app}.#{app_name}"
    end

    # data.sync.{app}.{dest}
    def source_subject
      "data.sync.#{app_name}.#{destination_app}"
    end

    def source_app
      app_name
    end
  end
end

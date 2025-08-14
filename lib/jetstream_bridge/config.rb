# frozen_string_literal: true

module JetstreamBridge
  class Config
    attr_accessor :nats_urls, :env, :app_name, :stream_name,
                  :max_deliver, :backoff, :dlq_subject, :ack_wait,
                  :use_outbox, :use_inbox, :outbox_model, :inbox_model,
                  :publisher_persistent,
                  :source_app, :destination_app

    def initialize
      @nats_urls   = ENV['NATS_URLS'] || 'nats://localhost:4222'
      @env         = ENV['NATS_ENV']  || 'development'
      @app_name    = ENV['APP_NAME']  || 'app'

      # Explicit app source/destination for filtering subjects
      @source_app      = ENV['JTS_SOURCE_APP']      || @app_name
      @destination_app = ENV['JTS_DESTINATION_APP'] || nil # optional, e.g., "hw" or "pwas"

      @stream_name = "#{@env}-data-sync"
      @dlq_subject = "#{@env}.data.sync.dlq"

      @max_deliver = 5
      @ack_wait    = '30s'
      @backoff     = %w[1s 5s 15s 30s 60s]

      # Reliability mode toggles
      @use_outbox  = false
      @use_inbox   = false
      @outbox_model = 'JetstreamBridge::OutboxEvent'
      @inbox_model  = 'JetstreamBridge::InboxEvent'

      # Publisher connection mode
      @publisher_persistent = true
    end
  end
end

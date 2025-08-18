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

    # Single stream name per env
    def stream_name = "#{env}-stream-bridge"

    # Base subjects (no trailing .>)
    # Producer publishes to:   {env}.data.sync.{app}.{dest}.<resource>.<event>
    # Consumer subscribes to:  {env}.data.sync.{dest}.{app}.>
    def source_subject = "#{env}.data.sync.#{app_name}.#{destination_app}"
    def dest_subject   = "#{env}.data.sync.#{destination_app}.#{app_name}"

    # Subject roots with .>
    def producer_root  = "#{source_subject}.>"
    def consumer_root  = "#{dest_subject}.>"

    # DLQ
    def dlq_subject    = "#{env}.data.sync.dlq"

    # Pairing helpers (for docs/logs/tests)
    # In the *other* system, APP_NAME and DESTINATION_APP swap.
    # Therefore:
    #   my_consumer_root == their_producer_root
    #   my_producer_root == their_consumer_root
    def counterpart_producer_root = consumer_root
    def counterpart_consumer_root = producer_root
  end
end

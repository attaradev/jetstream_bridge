# frozen_string_literal: true

require_relative 'stream'
require_relative 'config'
require_relative 'logging'

module JetstreamBridge
  class Topology
    def self.ensure!(jts)
      cfg = JetstreamBridge.config
      subjects = [cfg.producer_root, cfg.consumer_root]
      subjects << cfg.dlq_subject if cfg.use_dlq
      Stream.ensure!(jts, cfg.stream_name, subjects)

      # Optional: log the cross-system pairing for clarity
      Logging.info(
        "Subjects ready: producer=#{cfg.producer_root}, consumer=#{cfg.consumer_root}. "\
          "Counterpart is expected to publish on #{cfg.counterpart_producer_root} and "\
          "subscribe on #{cfg.counterpart_consumer_root}.",
        tag: 'JetstreamBridge::Topology'
      )
    end
  end
end

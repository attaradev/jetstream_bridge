# frozen_string_literal: true

require_relative 'stream'
require_relative 'config'
require_relative 'logging'

module JetstreamBridge
  class Topology
    def self.ensure!(jts)
      cfg = JetstreamBridge.config
      subjects = [cfg.source_subject, cfg.destination_subject]
      subjects << cfg.dlq_subject if cfg.use_dlq
      Stream.ensure!(jts, cfg.stream_name, subjects)

      Logging.info(
        "Subjects ready: producer=#{cfg.source_subject}, consumer=#{cfg.destination_subject}. " \
          "Counterpart publishes on #{cfg.destination_subject} and subscribes on #{cfg.source_subject}.",
        tag: 'JetstreamBridge::Topology'
      )
    end
  end
end

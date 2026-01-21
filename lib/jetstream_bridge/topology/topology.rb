# frozen_string_literal: true

require_relative '../core/config'
require_relative '../core/logging'
require_relative 'stream'

module JetstreamBridge
  class Topology
    def self.ensure!(jts, force: false)
      cfg = JetstreamBridge.config
      if cfg.disable_js_api && !force
        Logging.info('Topology ensure skipped (JS API disabled).', tag: 'JetstreamBridge::Topology')
        return
      end

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

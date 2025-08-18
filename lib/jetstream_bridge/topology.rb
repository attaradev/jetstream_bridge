# frozen_string_literal: true

require_relative 'stream'
require_relative 'dlq'

module JetstreamBridge
  # Ensures that the Jetstream topology is in place.
  class Topology
    def self.ensure!(jts)
      root = "#{JetstreamBridge.config.env}.data.sync.>"
      Stream.ensure!(jts, JetstreamBridge.config.stream_name, [root])
      DLQ.ensure!(jts) if JetstreamBridge.config.use_dlq
    end
  end
end

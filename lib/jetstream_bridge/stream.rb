# frozen_string_literal: true

module JetstreamBridge
  # Ensures a stream exists.
  class Stream
    def self.ensure!(jts, name, subjects)
      OverlapGuard.check!(jts, name, subjects)

      jts.stream_info(name)
      Logging.info("Stream #{name} exists.", tag: 'JetstreamBridge::Stream')
    rescue NATS::JetStream::Error => e
      raise unless e.message =~ /stream not found/i

      jts.add_stream(name: name, subjects: subjects, retention: 'interest', storage: 'file')
      Logging.info("Created stream #{name} subjects=#{subjects.inspect}", tag: 'JetstreamBridge::Stream')
    end
  end
end

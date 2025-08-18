# frozen_string_literal: true

require_relative 'overlap_guard'
require_relative 'logging'

module JetstreamBridge
  # Ensures a stream exists and adds only subjects that are not already present.
  class Stream
    class << self
      def ensure!(jts, name, subjects)
        desired = Array(subjects).map!(&:to_s).uniq
        raise ArgumentError, 'subjects must not be empty' if desired.empty?

        info = jts.stream_info(name)
        existing = Array(info.config.subjects || []).map!(&:to_s).uniq

        missing = desired - existing
        if missing.empty?
          Logging.info("Stream #{name} exists; subjects already present.", tag: 'JetstreamBridge::Stream')
          return
        end

        # Validate only what we're adding (against other streams)
        OverlapGuard.check!(jts, name, existing + missing)

        new_subjects = (existing + missing).uniq
        jts.update_stream(name: name, subjects: new_subjects)
        Logging.info("Updated stream #{name}; added subjects=#{missing.inspect}", tag: 'JetstreamBridge::Stream')
      rescue NATS::JetStream::Error => e
        # If a stream doesn't exist, create it with the requested subjects (after overlap check)
        if e.message =~ /stream not found/i
          OverlapGuard.check!(jts, name, desired)
          jts.add_stream(name: name, subjects: desired, retention: 'interest', storage: 'file')
          Logging.info("Created stream #{name} subjects=#{desired.inspect}", tag: 'JetstreamBridge::Stream')
        else
          raise
        end
      end
    end
  end
end

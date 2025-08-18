# frozen_string_literal: true

require_relative 'overlap_guard'
require_relative 'logging'
require_relative 'subject_matcher'

module JetstreamBridge
  # Ensures a stream exists and adds only subjects that are not already covered.
  class Stream
    class << self
      def ensure!(jts, name, subjects)
        desired = normalize_subjects(subjects)
        raise ArgumentError, 'subjects must not be empty' if desired.empty?

        begin
          info     = jts.stream_info(name)
          existing = normalize_subjects(info.config.subjects || [])

          # Skip anything already COVERED by existing patterns (not just exact match)
          missing = desired.reject { |d| SubjectMatcher.covered?(existing, d) }
          if missing.empty?
            Logging.info("Stream #{name} exists; subjects already covered.", tag: 'JetstreamBridge::Stream')
            return
          end

          # Validate full target set against other streams
          target = (existing + missing).uniq
          OverlapGuard.check!(jts, name, target)

          # Try to update; handle late overlaps/races
          jts.update_stream(name: name, subjects: target)
          Logging.info("Updated stream #{name}; added subjects=#{missing.inspect}", tag: 'JetstreamBridge::Stream')
        rescue NATS::JetStream::Error => e
          if stream_not_found?(e)
            # Race: created elsewhere or genuinely missing — create fresh
            OverlapGuard.check!(jts, name, desired)
            jts.add_stream(name: name, subjects: desired, retention: 'interest', storage: 'file')
            Logging.info("Created stream #{name} subjects=#{desired.inspect}", tag: 'JetstreamBridge::Stream')
          elsif overlap_error?(e)
            # Late overlap due to concurrent change — recompute and raise with details
            conflicts = OverlapGuard.overlaps(jts, name, desired)
            raise OverlapGuard.conflict_message(name, conflicts)
          else
            raise
          end
        end
      end

      private

      def normalize_subjects(list)
        Array(list).flatten.compact.map!(&:to_s).reject(&:empty?).uniq
      end

      def stream_not_found?(error)
        msg = error.message.to_s
        msg =~ /stream\s+not\s+found/i || msg =~ /\b404\b/
      end

      def overlap_error?(error)
        msg = error.message.to_s
        msg =~ /subjects?\s+overlap/i || msg =~ /\berr_code=10065\b/ || msg =~ /\bstatus_code=400\b/
      end
    end
  end
end

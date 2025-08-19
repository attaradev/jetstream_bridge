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

        attempts = 0

        begin
          info     = jts.stream_info(name)
          existing = normalize_subjects(info.config.subjects || [])

          # Skip anything already COVERED by existing patterns (not just exact match)
          to_add = desired.reject { |d| SubjectMatcher.covered?(existing, d) }
          if to_add.empty?
            Logging.info("Stream #{name} exists; subjects already covered.", tag: 'JetstreamBridge::Stream')
            return
          end

          # Filter out subjects owned by other streams to prevent overlap BadRequest
          allowed, blocked = OverlapGuard.partition_allowed(jts, name, to_add)

          if allowed.empty?
            if blocked.any?
              Logging.warn(
                "Stream #{name}: all missing subjects are owned by other streams; leaving unchanged. " \
                  "blocked=#{blocked.inspect}",
                tag: 'JetstreamBridge::Stream'
              )
            else
              Logging.info("Stream #{name} exists; nothing to add.", tag: 'JetstreamBridge::Stream')
            end
            return
          end

          target = (existing + allowed).uniq

          # Validate and update (race may still occur; handled in rescue)
          OverlapGuard.check!(jts, name, target)
          jts.update_stream(name: name, subjects: target)

          Logging.info(
            "Updated stream #{name}; added subjects=#{allowed.inspect}" \
              "#{blocked.any? ? " (skipped overlapped=#{blocked.inspect})" : ''}",
            tag: 'JetstreamBridge::Stream'
          )
        rescue NATS::JetStream::Error => e
          if stream_not_found?(e)
            # Creating fresh: still filter to avoid BadRequest
            allowed, blocked = OverlapGuard.partition_allowed(jts, name, desired)
            if allowed.empty?
              Logging.warn(
                "Not creating stream #{name}: all desired subjects are owned by other streams. " \
                  "blocked=#{blocked.inspect}",
                tag: 'JetstreamBridge::Stream'
              )
              return
            end

            jts.add_stream(
              name: name,
              subjects: allowed,
              retention: 'interest',
              storage: 'file'
            )
            Logging.info(
              "Created stream #{name} subjects=#{allowed.inspect}" \
                "#{blocked.any? ? " (skipped overlapped=#{blocked.inspect})" : ''}",
              tag: 'JetstreamBridge::Stream'
            )
          elsif overlap_error?(e) && (attempts += 1) <= 1
            # Late race: re-fetch and try once more
            Logging.warn("Overlap race while ensuring #{name}; retrying once...", tag: 'JetstreamBridge::Stream')
            sleep(0.05)
            retry
          elsif overlap_error?(e)
            # Give up gracefully (don’t raise) — someone else now owns a conflicting subject
            Logging.warn(
              "Overlap persists ensuring #{name}; leaving unchanged. err=#{e.message.inspect}",
              tag: 'JetstreamBridge::Stream'
            )
            return
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

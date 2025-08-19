# frozen_string_literal: true

require_relative '../core/logging'
require_relative 'overlap_guard'
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
          info = safe_stream_info(jts, name)
          info ? ensure_update(jts, name, info, desired) : ensure_create(jts, name, desired)
        rescue NATS::JetStream::Error => e
          if overlap_error?(e) && (attempts += 1) <= 1
            Logging.warn("Overlap race while ensuring #{name}; retrying once...", tag: 'JetstreamBridge::Stream')
            sleep(0.05)
            retry
          elsif overlap_error?(e)
            Logging.warn(
              "Overlap persists ensuring #{name}; leaving unchanged. err=#{e.message.inspect}",
              tag: 'JetstreamBridge::Stream')
            nil
          else
            raise
          end
        end
      end

      private

      # ---------- Update existing stream ----------

      def ensure_update(jts, name, info, desired)
        existing = normalize_subjects(info.config.subjects || [])
        to_add   = missing_subjects(existing, desired)
        return log_already_covered(name) if to_add.empty?

        allowed, blocked = OverlapGuard.partition_allowed(jts, name, to_add)
        return log_all_blocked(name, blocked) if allowed.empty?

        target = (existing + allowed).uniq
        OverlapGuard.check!(jts, name, target)
        jts.update_stream(name: name, subjects: target)
        log_updated(name, allowed, blocked)
      end

      # ---------- Create new stream ----------

      def ensure_create(jts, name, desired)
        allowed, blocked = OverlapGuard.partition_allowed(jts, name, desired)
        return log_not_created(name, blocked) if allowed.empty?

        jts.add_stream(name: name, subjects: allowed, retention: 'interest', storage: 'file')
        log_created(name, allowed, blocked)
      end

      # ---------- Helpers ----------

      def safe_stream_info(jts, name)
        jts.stream_info(name)
      rescue NATS::JetStream::Error => e
        return nil if stream_not_found?(e)
        raise
      end

      def missing_subjects(existing, desired)
        desired.reject { |d| SubjectMatcher.covered?(existing, d) }
      end

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

      # ---------- Logging wrappers ----------

      def log_already_covered(name)
        Logging.info("Stream #{name} exists; subjects already covered.", tag: 'JetstreamBridge::Stream')
      end

      def log_all_blocked(name, blocked)
        if blocked.any?
          Logging.warn(
            "Stream #{name}: all missing subjects are owned by other streams; leaving unchanged. " \
            "blocked=#{blocked.inspect}",
            tag: 'JetstreamBridge::Stream'
          )
        else
          Logging.info("Stream #{name} exists; nothing to add.", tag: 'JetstreamBridge::Stream')
        end
      end

      def log_updated(name, added, blocked)
        msg = "Updated stream #{name}; added subjects=#{added.inspect}"
        msg += " (skipped overlapped=#{blocked.inspect})" if blocked.any?
        Logging.info(msg, tag: 'JetstreamBridge::Stream')
      end

      def log_not_created(name, blocked)
        Logging.warn(
          "Not creating stream #{name}: all desired subjects are owned by other streams. " \
          "blocked=#{blocked.inspect}",
          tag: 'JetstreamBridge::Stream'
        )
      end

      def log_created(name, allowed, blocked)
        msg = "Created stream #{name} subjects=#{allowed.inspect}"
        msg += " (skipped overlapped=#{blocked.inspect})" if blocked.any?
        Logging.info(msg, tag: 'JetstreamBridge::Stream')
      end
    end
  end
end

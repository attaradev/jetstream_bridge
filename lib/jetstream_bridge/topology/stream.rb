# frozen_string_literal: true

require_relative '../core/logging'
require_relative 'overlap_guard'
require_relative 'subject_matcher'

module JetstreamBridge
  module StreamSupport
    module_function

    def normalize_subjects(list)
      Array(list).flatten.compact.map!(&:to_s).reject(&:empty?).uniq
    end

    def missing_subjects(existing, desired)
      desired.reject { |d| SubjectMatcher.covered?(existing, d) }
    end

    def stream_not_found?(error)
      msg = error.message.to_s
      msg =~ /stream\s+not\s+found/i || msg =~ /\b404\b/
    end

    def overlap_error?(error)
      msg = error.message.to_s
      msg =~ /subjects?\s+overlap/i || msg =~ /\berr_code=10065\b/ || msg =~ /\b400\b/
    end

    # ---- Logging ----
    def log_already_covered(name)
      Logging.info(
        "Stream #{name} exists; subjects and config already covered.",
        tag: 'JetstreamBridge::Stream'
      )
    end

    def log_all_blocked(name, blocked)
      if blocked.any?
        Logging.warn(
          "Stream #{name}: all missing subjects belong to other streams; unchanged. blocked=#{blocked.inspect}",
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
        "Not creating stream #{name}: all desired subjects belong to other streams. blocked=#{blocked.inspect}",
        tag: 'JetstreamBridge::Stream'
      )
    end

    def log_created(name, allowed, blocked, retention, storage)
      msg = [
        "Created stream #{name}",
        "subjects=#{allowed.inspect}",
        "retention=#{retention.inspect}",
        "storage=#{storage.inspect}"
      ].join(' ')
      msg += " (skipped overlapped=#{blocked.inspect})" if blocked.any?
      Logging.info(msg, tag: 'JetstreamBridge::Stream')
    end

    def log_config_updated(name, storage:)
      Logging.info(
        "Updated stream #{name} config; storage=#{storage.inspect}",
        tag: 'JetstreamBridge::Stream'
      )
    end

    def log_retention_mismatch(name, have:, want:)
      Logging.warn(
        "Stream #{name} retention mismatch (have=#{have.inspect}, want=#{want.inspect}). " \
        "Retention is immutable; skipping retention change.",
        tag: 'JetstreamBridge::Stream'
      )
    end
  end

  # Ensures a stream exists and updates only uncovered subjects, using work-queue semantics.
  class Stream
    RETENTION = 'workqueue'
    STORAGE   = 'file'

    class << self
      def ensure!(jts, name, subjects)
        desired = StreamSupport.normalize_subjects(subjects)
        raise ArgumentError, 'subjects must not be empty' if desired.empty?

        attempts = 0
        begin
          info = safe_stream_info(jts, name)
          info ? ensure_update(jts, name, info, desired) : ensure_create(jts, name, desired)
        rescue NATS::JetStream::Error => e
          if StreamSupport.overlap_error?(e) && (attempts += 1) <= 1
            Logging.warn("Overlap race while ensuring #{name}; retrying once...", tag: 'JetstreamBridge::Stream')
            sleep(0.05)
            retry
          elsif StreamSupport.overlap_error?(e)
            Logging.warn("Overlap persists ensuring #{name}; leaving unchanged. err=#{e.message.inspect}",
                         tag: 'JetstreamBridge::Stream')
            nil
          else
            raise
          end
        end
      end

      private

      def ensure_update(jts, name, info, desired_subjects)
        existing = StreamSupport.normalize_subjects(info.config.subjects || [])
        to_add   = StreamSupport.missing_subjects(existing, desired_subjects)
        add_subjects(jts, name, existing, to_add) if to_add.any?

        # Retention is immutable; warn if different and do not include on update.
        have_ret = info.config.retention.to_s.downcase
        if have_ret != RETENTION
          StreamSupport.log_retention_mismatch(name, have: have_ret, want: RETENTION)
        end

        # Storage can be updated; do it without passing retention.
        have_storage = info.config.storage.to_s.downcase
        if have_storage != STORAGE
          apply_update(jts, name, existing, storage: STORAGE)
          StreamSupport.log_config_updated(name, storage: STORAGE)
          return
        end

        return if to_add.any?

        StreamSupport.log_already_covered(name)
      end

      # ---- tiny helpers extracted to reduce ABC ----
      def add_subjects(jts, name, existing, to_add)
        allowed, blocked = OverlapGuard.partition_allowed(jts, name, to_add)
        return StreamSupport.log_all_blocked(name, blocked) if allowed.empty?

        target = (existing + allowed).uniq
        OverlapGuard.check!(jts, name, target)
        # Do not pass retention on update to avoid 10052.
        apply_update(jts, name, target)
        StreamSupport.log_updated(name, allowed, blocked)
      end

      # Only include mutable fields on update (subjects, storage). Never retention.
      def apply_update(jts, name, subjects, storage: nil)
        params = { name: name, subjects: subjects }
        params[:storage] = storage if storage
        jts.update_stream(**params)
      end

      def ensure_create(jts, name, desired_subjects)
        allowed, blocked = OverlapGuard.partition_allowed(jts, name, desired_subjects)
        return StreamSupport.log_not_created(name, blocked) if allowed.empty?

        jts.add_stream(
          name: name,
          subjects: allowed,
          retention: RETENTION,
          storage: STORAGE
        )
        StreamSupport.log_created(name, allowed, blocked, RETENTION, STORAGE)
      end

      def safe_stream_info(jts, name)
        jts.stream_info(name)
      rescue NATS::JetStream::Error => e
        return nil if StreamSupport.stream_not_found?(e)

        raise
      end
    end
  end
end

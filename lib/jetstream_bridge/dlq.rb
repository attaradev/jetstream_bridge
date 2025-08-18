# frozen_string_literal: true

require_relative 'overlap_guard'
require_relative 'logging'
require_relative 'subject_matcher'

module JetstreamBridge
  # Ensures the DLQ subject is added to the stream.
  class DLQ
    def self.ensure!(jts)
      name  = JetstreamBridge.config.stream_name
      info  = jts.stream_info(name)
      subs  = Array(info.config.subjects || [])
      dlq   = JetstreamBridge.config.dlq_subject
      return if SubjectMatcher.covered?(subs, dlq)

      desired = (subs + [dlq]).uniq
      OverlapGuard.check!(jts, name, desired)

      jts.update_stream(name: name, subjects: desired)
      Logging.info("Added DLQ subject #{dlq} to stream #{name}", tag: 'JetstreamBridge::DLQ')
    end
  end
end

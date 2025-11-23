# frozen_string_literal: true

require 'oj'
require_relative 'subject_matcher'
require_relative '../core/logging'

module JetstreamBridge
  # Checks for overlapping subjects.
  class OverlapGuard
    class << self
      # Raise if any desired subjects conflict with other streams.
      def check!(jts, target_name, new_subjects)
        conflicts = overlaps(jts, target_name, new_subjects)
        return if conflicts.empty?

        raise conflict_message(target_name, conflicts)
      end

      # Return a list of conflicts against other streams, per subject.
      # [{ name:'OTHER' pairs: [['a.b.*', 'a.b.c'], ...] }, ...]
      def overlaps(jts, target_name, new_subjects)
        desired = Array(new_subjects).map!(&:to_s).uniq
        streams = list_streams_with_subjects(jts)
        others  = streams.reject { |s| s[:name] == target_name }

        others.filter_map do |s|
          pairs = desired.flat_map do |n|
            Array(s[:subjects]).map(&:to_s).select { |e| SubjectMatcher.overlap?(n, e) }
                               .map { |e| [n, e] }
          end
          { name: s[:name], pairs: pairs } unless pairs.empty?
        end
      end

      # Returns [allowed, blocked] given desired subjects.
      def partition_allowed(jts, target_name, desired_subjects)
        desired   = Array(desired_subjects).map!(&:to_s).uniq
        conflicts = overlaps(jts, target_name, desired)
        blocked   = conflicts.flat_map { |c| c[:pairs].map(&:first) }.uniq
        allowed   = desired - blocked
        [allowed, blocked]
      end

      def allowed_subjects(jts, target_name, desired_subjects)
        partition_allowed(jts, target_name, desired_subjects).first
      end

      def list_streams_with_subjects(jts)
        list_stream_names(jts).map do |name|
          info = jts.stream_info(name)
          # Handle both object-style and hash-style access for compatibility
          config_data = info.config
          subjects = config_data.respond_to?(:subjects) ? config_data.subjects : config_data[:subjects]
          { name: name, subjects: Array(subjects || []) }
        end
      end

      def list_stream_names(jts)
        names  = []
        offset = 0
        max_iterations = 100 # Safety limit to prevent infinite loops
        iterations = 0

        loop do
          iterations += 1
          if iterations > max_iterations
            Logging.warn(
              "Stream listing exceeded max iterations (#{max_iterations}), returning #{names.size} streams",
              tag: 'JetstreamBridge::OverlapGuard'
            )
            break
          end

          resp  = js_api_request(jts, '$JS.API.STREAM.NAMES', { offset: offset })
          batch = Array(resp['streams']).filter_map { |h| h['name'] }
          names.concat(batch)
          total = resp['total'].to_i

          break if names.size >= total || batch.empty?

          offset = names.size
        end
        names
      end

      def js_api_request(jts, subject, payload = {})
        # JetStream client should expose the underlying NATS client as `nc`
        msg = jts.nc.request(subject, Oj.dump(payload, mode: :compat))
        Oj.load(msg.data, mode: :strict)
      end

      def conflict_message(target, conflicts)
        msg = "Overlapping subjects for stream #{target}:\n"
        conflicts.each do |c|
          msg << "- Conflicts with '#{c[:name]}' on:\n"
          c[:pairs].each { |(a, b)| msg << "    • #{a} × #{b}\n" }
        end
        msg
      end
    end
  end
end

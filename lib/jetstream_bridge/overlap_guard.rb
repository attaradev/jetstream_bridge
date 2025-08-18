# frozen_string_literal: true

require 'json'

module JetstreamBridge
  # Checks for overlapping subjects.
  class OverlapGuard
    class << self
      def check!(jts, target_name, new_subjects)
        conflicts = overlaps(jts, target_name, new_subjects)
        return if conflicts.empty?
        raise conflict_message(target_name, conflicts)
      end

      def overlaps(jts, target_name, new_subjects)
        desired = Array(new_subjects).map!(&:to_s).uniq
        streams = list_streams_with_subjects(jts)
        others  = streams.reject { |s| s[:name] == target_name }

        others.map do |s|
          pairs = desired.flat_map do |n|
            Array(s[:subjects]).map(&:to_s).select { |e| SubjectMatcher.overlap?(n, e) }
                               .map { |e| [n, e] }
          end
          { name: s[:name], pairs: pairs } unless pairs.empty?
        end.compact
      end

      def list_streams_with_subjects(jts)
        list_stream_names(jts).map do |name|
          info = jts.stream_info(name)
          { name: name, subjects: Array(info.config.subjects || []) }
        end
      end

      def list_stream_names(jts)
        names  = []
        offset = 0
        loop do
          resp  = js_api_request(jts, '$JS.API.STREAM.NAMES', { offset: offset })
          batch = Array(resp['streams']).map { |h| h['name'] }.compact
          names.concat(batch)
          break if names.size >= resp['total'].to_i || batch.empty?
          offset = names.size
        end
        names
      end

      def js_api_request(jts, subject, payload = {})
        # JetStream client should expose the underlying NATS client as `nc`
        msg = jts.nc.request(subject, JSON.dump(payload))
        JSON.parse(msg.data)
      end

      def conflict_message(target, conflicts)
        msg = +"Overlapping subjects for stream #{target}:\n"
        conflicts.each do |c|
          msg << "- Conflicts with '#{c[:name]}' on:\n"
          c[:pairs].each { |(a, b)| msg << "    • #{a} × #{b}\n" }
        end
        msg
      end
    end
  end
end

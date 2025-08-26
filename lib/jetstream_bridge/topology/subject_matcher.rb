# frozen_string_literal: true

module JetstreamBridge
  # Subject matching helpers.
  module SubjectMatcher
    module_function

    def covered?(patterns, subject)
      Array(patterns).any? { |pat| match?(pat.to_s, subject.to_s) }
    end

    # Proper NATS semantics:
    # - '*' matches exactly one token
    # - '>' matches the rest (zero or more tokens)
    def match?(pattern, subject)
      p = pattern.split('.')
      s = subject.split('.')

      i = 0
      while i < p.length && i < s.length
        token = p[i]
        case token
        when '>'
          return true # tail wildcard absorbs the rest
        when '*'
          # matches this token; continue
        else
          return false unless token == s[i]
        end
        i += 1
      end

      # Exact match
      return true if i == p.length && i == s.length

      # If pattern has remaining '>' it can absorb remainder
      p[i] == '>' || p[i..]&.include?('>')
    end

    # Do two wildcard patterns admit at least one same subject?
    def overlap?(sub_a, sub_b)
      overlap_parts?(sub_a.split('.'), sub_b.split('.'))
    end

    def overlap_parts?(a_parts, b_parts)
      ai = 0
      bi = 0
      while ai < a_parts.length && bi < b_parts.length
        at = a_parts[ai]
        bt = b_parts[bi]
        return true if tail?(at, bt)
        return false unless token_match?(at, bt)

        ai += 1
        bi += 1
      end

      tail_overlap?(a_parts[ai..], b_parts[bi..])
    end

    def tail?(a_token, b_token)
      a_token == '>' || b_token == '>'
    end

    def token_match?(a_token, b_token)
      a_token == b_token || a_token == '*' || b_token == '*'
    end

    def tail_overlap?(a_tail, b_tail)
      a_tail ||= []
      b_tail ||= []
      return true if a_tail.include?('>') || b_tail.include?('>')

      a_tail.empty? && b_tail.empty?
    end
  end
end

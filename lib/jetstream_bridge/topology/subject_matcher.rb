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
      p[i] == '>' || p[i..-1]&.include?('>')
    end

    # Do two wildcard patterns admit at least one same subject?
    def overlap?(a, b)
      overlap_parts?(a.split('.'), b.split('.'))
    end

    def overlap_parts?(a_parts, b_parts)
      ai = 0
      bi = 0
      while ai < a_parts.length && bi < b_parts.length
        at = a_parts[ai]
        bt = b_parts[bi]
        return true if at == '>' || bt == '>'
        return false unless at == bt || at == '*' || bt == '*'
        ai += 1
        bi += 1
      end

      # If any side still has a '>' remaining, it can absorb the other's remainder
      a_tail = a_parts[ai..-1] || []
      b_tail = b_parts[bi..-1] || []
      return true if a_tail.include?('>') || b_tail.include?('>')

      # Otherwise they overlap only if both consumed exactly
      ai == a_parts.length && bi == b_parts.length
    end
  end
end

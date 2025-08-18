# frozen_string_literal: true

module JetstreamBridge
  # Subject matching helpers.
  module SubjectMatcher
    def self.covered?(patterns, subject)
      patterns.any? { |pat| match?(pat, subject) }
    end

    def self.match?(pattern, subject)
      p = pattern.split('.')
      s = subject.split('.')
      return true if p.include?('>')
      return false if p.size != s.size

      p.zip(s).all? { |a, b| a == '*' || a == b }
    end

    def self.overlap?(a, b)
      a_parts = a.split('.')
      b_parts = b.split('.')
      overlap_parts?(a_parts, b_parts)
    end

    def self.overlap_parts?(a_parts, b_parts)
      ai = bi = 0
      while ai < a_parts.length && bi < b_parts.length
        at = a_parts[ai]
        bt = b_parts[bi]
        return true if at == '>' || bt == '>'
        return false unless at == bt || at == '*' || bt == '*'

        ai += 1
        bi += 1
      end
      a_parts[ai..].include?('>') || b_parts[bi..].include?('>') || (ai == a_parts.length && bi == b_parts.length)
    end
  end
end

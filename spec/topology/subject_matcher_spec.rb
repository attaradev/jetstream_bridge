# frozen_string_literal: true

require 'jetstream_bridge/topology/subject_matcher'

RSpec.describe JetstreamBridge::SubjectMatcher do
  describe '.match?' do
    it 'matches exact subjects' do
      expect(described_class.match?('a.b', 'a.b')).to be true
      expect(described_class.match?('a.b', 'a.c')).to be false
    end

    it 'supports single-token wildcards' do
      expect(described_class.match?('a.*.c', 'a.b.c')).to be true
      expect(described_class.match?('a.*.c', 'a.b.d')).to be false
    end

    it 'requires * to consume exactly one token' do
      expect(described_class.match?('a.*', 'a')).to be false
      expect(described_class.match?('*', 'a.b')).to be false
    end

    it 'supports tail wildcards' do
      expect(described_class.match?('a.>', 'a.b.c')).to be true
      expect(described_class.match?('>', 'a.b.c')).to be true
      expect(described_class.match?('a.>', 'b.c')).to be false
    end
  end

  describe '.covered?' do
    it 'returns true when any pattern matches the subject' do
      patterns = ['a.*', 'b.>']
      expect(described_class.covered?(patterns, 'a.b')).to be true
      expect(described_class.covered?(patterns, 'b.c.d')).to be true
      expect(described_class.covered?(patterns, 'c')).to be false
    end
  end

  describe '.overlap?' do
    it 'detects overlapping wildcard patterns' do
      expect(described_class.overlap?('a.*.c', 'a.b.*')).to be true
      expect(described_class.overlap?('a.*.c', 'a.*.d')).to be false
      expect(described_class.overlap?('a.>', 'a')).to be true
      expect(described_class.overlap?('a.*', 'a')).to be false
    end
  end
end
